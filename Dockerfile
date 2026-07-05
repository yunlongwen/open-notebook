# =============================================================================
# Open Notebook — Multi-stage Docker build (memory-optimized, CN-mirror)
# =============================================================================
# Stages: frontend-builder → backend-builder → runtime
# Frontend and backend builds run in SEPARATE stages so they never compete
# for RAM in the same container.
#
# Memory optimizations:
#   - Parallel compilation capped at 2 jobs (avoids OOM on 4 GB hosts)
#   - Node.js heap limited to 1536 MB
#   - uv builds/downloads throttled
# =============================================================================

ARG APT_MIRROR=mirrors.tuna.tsinghua.edu.cn
ARG NPM_REGISTRY=https://registry.npmmirror.com

# ---------------------------------------------------------------------------
# Stage 1: Frontend Builder
# ---------------------------------------------------------------------------
FROM node:22-slim AS frontend-builder
ARG NPM_REGISTRY
WORKDIR /app/frontend

# Constrain Node.js heap so Next.js / webpack doesn't blow through RAM
ENV NODE_OPTIONS="--max-old-space-size=1536"

COPY frontend/package.json frontend/package-lock.json ./
RUN npm config set registry ${NPM_REGISTRY} \
 && npm config set fetch-retries 5 \
 && npm config set fetch-retry-mintimeout 20000 \
 && npm config set fetch-retry-maxtimeout 120000
RUN i=0; until npm ci; do \
      i=$((i+1)); \
      if [ "$i" -ge 5 ]; then echo "npm ci failed after $i attempts"; exit 1; fi; \
      echo "npm ci failed (attempt $i); retrying in 15s"; sleep 15; \
    done

COPY frontend/ ./
RUN npm run build

# ---------------------------------------------------------------------------
# Stage 2: Backend Builder
# ---------------------------------------------------------------------------
FROM python:3.12-slim-trixie AS backend-builder
ARG APT_MIRROR

# Install uv (for tiktoken cache and potential future use)
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

RUN sed -i "s|deb.debian.org|${APT_MIRROR}|g; s|security.debian.org|${APT_MIRROR}|g" /etc/apt/sources.list.d/debian.sources 2>/dev/null || \
    sed -i "s|deb.debian.org|${APT_MIRROR}|g; s|security.debian.org|${APT_MIRROR}|g" /etc/apt/sources.list && \
    apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# --- Memory-conservation build settings ---
ENV MAKEFLAGS="-j2"
ENV PIP_NO_CACHE_DIR=1
ENV PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
ENV PIP_TRUSTED_HOST=pypi.tuna.tsinghua.edu.cn
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /app

# Copy dependency files first for caching
COPY pyproject.toml uv.lock ./
COPY open_notebook/__init__.py ./open_notebook/__init__.py

# Install dependencies using pip (more reliable with Chinese mirrors than uv)
# First generate requirements list from the lock file, then pip install
# Install all dependencies from pyproject.toml using pip with Tsinghua mirror
RUN pip install --timeout 120 setuptools wheel && pip install --timeout 120 . --no-build-isolation
    # Dependencies are read from pyproject.toml

# Pre-download tiktoken encoding so the app works offline
ENV TIKTOKEN_CACHE_DIR=/app/tiktoken-cache
RUN mkdir -p /app/tiktoken-cache && \
    python -c "import tiktoken; tiktoken.get_encoding('o200k_base')"

# ---------------------------------------------------------------------------
# Stage 3: Runtime
# ---------------------------------------------------------------------------
FROM python:3.12-slim-trixie AS runtime
ARG APT_MIRROR

RUN sed -i "s|deb.debian.org|${APT_MIRROR}|g; s|security.debian.org|${APT_MIRROR}|g" /etc/apt/sources.list.d/debian.sources 2>/dev/null || \
    sed -i "s|deb.debian.org|${APT_MIRROR}|g; s|security.debian.org|${APT_MIRROR}|g" /etc/apt/sources.list && \
    apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
    ffmpeg supervisor curl \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/
WORKDIR /app

COPY --from=backend-builder /usr/local/lib/python3.12/site-packages/ /usr/local/lib/python3.12/site-packages/
COPY --from=backend-builder /usr/local/bin/ /usr/local/bin/
COPY . /app/
COPY --from=backend-builder /app/tiktoken-cache /app/tiktoken-cache

ENV UV_NO_SYNC=1
ENV TIKTOKEN_CACHE_DIR=/app/tiktoken-cache
ENV HOSTNAME=0.0.0.0
ENV API_HOST=0.0.0.0

COPY --from=frontend-builder /app/frontend/.next/standalone /app/frontend/
COPY --from=frontend-builder /app/frontend/.next/static /app/frontend/.next/static
COPY --from=frontend-builder /app/frontend/public /app/frontend/public
COPY --from=frontend-builder /app/frontend/start-server.js /app/frontend/start-server.js

EXPOSE 8502 5055
RUN mkdir -p /app/data
COPY scripts/wait-for-api.sh /app/scripts/wait-for-api.sh
RUN chmod +x /app/scripts/wait-for-api.sh
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
RUN mkdir -p /var/log/supervisor

ENV VIRTUAL_ENV=/app/.venv

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]

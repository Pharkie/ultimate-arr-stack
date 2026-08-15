FROM node:20-bookworm-slim

WORKDIR /app

ENV DEBIAN_FRONTEND=noninteractive

# Runtime dependencies:
# - ffmpeg for subtitle sync tooling
# - python3/pip for ffsubsync
# - wget for the container healthcheck
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ffmpeg \
    python3 \
    python3-pip \
    wget \
    ca-certificates \
    build-essential \
    python3-setuptools \
  && python3 -m pip install --no-cache-dir --break-system-packages ffsubsync \
  && rm -rf /var/lib/apt/lists/*

# Install dependencies separately for better layer caching
COPY package*.json ./
RUN npm install --omit=dev

# Copy source
COPY . .

# Non-root user for security
RUN groupadd --system magnetio && useradd --system --gid magnetio --create-home magnetio
USER magnetio

EXPOSE 7000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
  CMD wget -qO- http://localhost:7000/health || exit 1

CMD ["node", "index.js"]

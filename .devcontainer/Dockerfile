FROM mcr.microsoft.com/devcontainers/base:ubuntu

# Node.js (for Claude Code + Playwright)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Docker CLI + Compose plugin (to manage the project's docker-compose stack)
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
       | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
       https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends \
       docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# Python3 + PyYAML (for pre-commit YAML validation and fix-radarr-paths.sh)
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-pip \
    && pip3 install --break-system-packages pyyaml \
    && rm -rf /var/lib/apt/lists/*

# sshpass (for NAS SSH access from scripts)
RUN apt-get update && apt-get install -y --no-install-recommends \
      sshpass \
    && rm -rf /var/lib/apt/lists/*

# Claude Code CLI (update npm first to suppress version warnings)
RUN npm install -g npm@latest && npm install -g @anthropic-ai/claude-code

# Playwright system deps (for running e2e tests)
RUN npx playwright install-deps chromium 2>/dev/null || true

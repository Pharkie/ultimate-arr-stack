# Runs the Playwright e2e suite on the NAS itself, where `npm`/`node` are not
# actually installed (the NAS OS only ships a stripped internal Node.js
# runtime for its own admin panel, with no npm) — mirrors this repo's
# existing pattern of containerizing tools the NAS OS lacks (see the
# alpine/git usage in nas-auto-deploy.yml and CLAUDE.md's Deploying section).
#
# docker.io (the CLI, not a full engine) is added so tests/e2e/helpers.ts's
# DOCKER_AVAILABLE gate can shell out to `docker exec`/`docker inspect`
# against the NAS's real daemon via the bind-mounted socket — required for
# the VPN egress/leak/killswitch and zombie-container checks to actually run
# instead of skipping.
FROM mcr.microsoft.com/playwright:v1.50.0-noble

RUN apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends docker.io \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /repo

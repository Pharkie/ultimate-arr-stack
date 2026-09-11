FROM node:21-slim

# Settings come from the compose service's `environment:` block and from
# nowhere else. This file used to carry ENV defaults too, including
# `JELLYFIN_PASSWORD "changeme"`; two sources for one setting is how they drift,
# and the value on this side was never the one in use. Removing them is also
# what a scanner needs to stop flagging the image: trivy's DS-0031 reads a
# variable name that looks like a secret, and an ENV line of any value looks
# like a credential baked into a layer. See docker-compose.arr-stack.yml's
# stremio-jellyfin service for the values that apply.
ENV SERVER_PORT 60421

RUN mkdir -p /home/node/app/node_modules && chown -R node:node /home/node/app
WORKDIR /home/node/app

COPY package*.json ./
COPY *.js ./

RUN chown -R node:node /home/node/app

USER node
# package-lock.json is gitignored (.gitignore:95), so this resolves against
# package.json on every build by design -- the lockfile that would pin it is not
# in the repository. The base image is pinned; see CONTRIBUTING.md, "Image
# pinning".
RUN npm install

EXPOSE $SERVER_PORT
ENTRYPOINT ["node", "server.js"]

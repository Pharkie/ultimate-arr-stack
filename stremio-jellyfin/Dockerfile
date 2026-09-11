FROM node:21-slim

ENV JELLYFIN_USER "changeme"
ENV JELLYFIN_PASSWORD "changeme"
ENV SERVER_PORT 60421
ENV JELLYFIN_SERVER "http://localhost"

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

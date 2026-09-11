FROM node:20-alpine

WORKDIR /app

COPY package*.json ./
# `npm ci`, not `npm install`: it installs exactly what a lockfile says. The
# catch is that package-lock.json is gitignored (.gitignore:95), so this only
# works where someone has run npm install in this directory first -- the build
# context carries the untracked lockfile even though git does not. A fresh clone
# fails here. The base image is pinned; see CONTRIBUTING.md, "Image pinning".
RUN npm ci --omit=dev

COPY . .

RUN addgroup -S magnetio && adduser -S magnetio -G magnetio
USER magnetio

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
  CMD wget -qO- http://localhost:8080/health || exit 1

CMD ["node", "index.js"]

# weatherfeels companion server
#
#   docker build -t weatherfeels-companion .
#   docker run -d -p 8080:8080 -e WS4K_TOKEN="$(openssl rand -hex 32)" \
#     -v ws4k-music:/data/music -v ws4k-ads:/data/ads weatherfeels-companion
#
# No dependencies to install: the image is Node plus four source folders.

FROM node:22-alpine

ENV NODE_ENV=production \
    WS4K_PORT=8080 \
    WS4K_MUSIC_DIR=/data/music \
    WS4K_ADS_DIR=/data/ads

WORKDIR /app

# Owned by root and read-only to the server; only /data is writable.
COPY package.json server.mjs ./
COPY lib ./lib
COPY admin ./admin

# The `node` user (uid 1000) ships with the base image. Creating the folders here
# gives fresh named volumes the right owner.
RUN mkdir -p /data/music /data/ads/images /data/ads/clips \
    && chown -R node:node /data

USER node

VOLUME ["/data/music", "/data/ads"]

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -q -O /dev/null "http://127.0.0.1:${WS4K_PORT}/health" || exit 1

CMD ["node", "server.mjs"]

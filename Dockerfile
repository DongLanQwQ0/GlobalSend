FROM node:24.19.0-bookworm-slim AS server-build
WORKDIR /build/server
COPY server/package.json server/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY server/src ./src
COPY server/tsconfig.json ./
COPY packages/protocol /build/packages/protocol
RUN npm run build && npm prune --omit=dev --no-audit --no-fund

FROM node:24.19.0-bookworm-slim AS web-build
WORKDIR /build/web
COPY web/package.json web/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY web/ ./
COPY packages/protocol /build/packages/protocol
RUN npm run build

FROM node:24.19.0-bookworm-slim AS runtime
ENV NODE_ENV=production HOST=0.0.0.0 PORT=8787 DATA_DIR=/data RELAY_DIR=/relay STATIC_DIR=/app/web/dist WEB_ENABLED=true
WORKDIR /app
COPY --from=server-build --chown=node:node /build/server/dist ./server/dist
COPY --from=server-build --chown=node:node /build/server/node_modules ./server/node_modules
COPY --from=server-build --chown=node:node /build/server/package.json ./server/package.json
COPY --from=web-build --chown=node:node /build/web/dist ./web/dist
RUN mkdir -p /data /relay && chown node:node /data /relay
USER node
EXPOSE 8787
STOPSIGNAL SIGTERM
CMD ["node", "server/dist/index.js"]

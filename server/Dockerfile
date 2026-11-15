FROM node:24-bookworm-slim AS build
RUN corepack enable
WORKDIR /app/server
COPY server/package.json server/pnpm-lock.yaml server/pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile
COPY server/tsconfig.json ./
COPY server/src ./src
RUN pnpm build && pnpm prune --prod

FROM node:24-bookworm-slim
# Links the published image to this repository so the release workflow may push it.
LABEL org.opencontainers.image.source="https://github.com/Alb11747/Vokoma"
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg && rm -rf /var/lib/apt/lists/*
WORKDIR /app/server
COPY --from=build /app/server/package.json ./
COPY --from=build /app/server/node_modules ./node_modules
COPY --from=build /app/server/dist ./dist
USER node
EXPOSE 3000
ENTRYPOINT ["node", "dist/main.js"]
CMD ["api"]

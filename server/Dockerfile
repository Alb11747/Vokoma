FROM node:24-bookworm-slim AS build
RUN corepack enable
WORKDIR /app/server
COPY server/package.json server/pnpm-lock.yaml server/pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile
COPY server/tsconfig.json ./
COPY server/src ./src
RUN pnpm build && pnpm prune --prod

# Keep Debian's probe and exact shared-library closure, without the ffmpeg
# executable or unrelated package files. Both stages use the same libc/base.
FROM node:24-bookworm-slim AS probe
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg \
    && mkdir -p /probe/usr/bin \
    && cp /usr/bin/ffprobe /probe/usr/bin/ \
    && for library in $(ldd /usr/bin/ffprobe | awk '/=> \// {print $3}'); do \
         case "$library" in /lib/*) destination="/probe/usr$library" ;; *) destination="/probe$library" ;; esac; \
         mkdir -p "$(dirname "$destination")" && cp -L "$library" "$destination" || exit 1; \
       done \
    && find /usr/share/doc -name copyright -exec cp --parents '{}' /probe \;

FROM node:24-bookworm-slim
# Links the published image to this repository so the release workflow may push it.
LABEL org.opencontainers.image.source="https://github.com/Alb11747/Vokoma"
COPY --from=probe /probe/ /
WORKDIR /app/server
COPY --from=build /app/server/package.json ./
COPY --from=build /app/server/node_modules ./node_modules
COPY --from=build /app/server/dist ./dist
# Stamp only the runtime package; source/contract generation stays deterministic.
ARG VOKOMA_VERSION=0.0.0
RUN VOKOMA_VERSION="$VOKOMA_VERSION" node --input-type=module -e 'import fs from "node:fs"; const p=JSON.parse(fs.readFileSync("package.json")); p.version=process.env.VOKOMA_VERSION; fs.writeFileSync("package.json", JSON.stringify(p)+"\n");'
USER node
EXPOSE 3000
ENTRYPOINT ["node", "dist/main.js"]
CMD ["api"]

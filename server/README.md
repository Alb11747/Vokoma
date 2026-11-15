# Vokoma server (M0 A)

Requires Linux, Node 24, pnpm 10.30.3 and ffmpeg/ffprobe on PATH. Linux `/proc`
provides descriptor-based path verification. Media roots are read only; the database
lives separately in the configured data directory. Only generated temporary media is
used by tests.

```sh
cd server
corepack enable
pnpm install --frozen-lockfile
pnpm hash-password < password-input
cp config.example.json config.json
# Fill in the account hash, roots, and data directory; create a random secret file
# containing at least 32 characters, readable only by the server account.
VOKOMA_CONFIG=config.json pnpm dev
```

Do not commit passwords, configuration, key files, or database files. Send passwords
in the login JSON body over HTTPS; access tokens go in Authorization headers. The
API never accepts credentials in query parameters. Put the service behind TLS for
remote access. Set `trustProxy` (passed to Fastify) to the reverse proxy's address
so clients are told apart by `X-Forwarded-For`; otherwise every client behind the
proxy shares one limit. The limiter refuses a client for a minute after five failed
logins; a successful login clears its count. At most two password checks run at once.

Configuration is JSON (`tokenSecretFile` or `tokenSecret` for the signing key). The
only environment overrides are `VOKOMA_CONFIG`, `VOKOMA_HOST` and
`VOKOMA_DATA_DIRECTORY`, which the container uses. Keep the data directory outside
media roots, owned by the process user. Container bind mounts need permissions for
the image's `node` user (UID 1000).

Access tokens last 15 minutes. Refresh tokens expire after 30 days without refresh,
rotate on use, and are stored only as SHA-256 hashes. For 60 seconds after a rotation
the previous refresh token still works and returns the same new token, so a client
that lost the response stays logged in. Logout immediately revokes both token types
for that device. Already running byte transfers finish normally.

`pnpm build` produces `dist/`; `node dist/main.js api` runs the server (with `tsx
src/main.ts` the same commands work from source). `devices` lists registered devices
and `revoke <device id>` revokes one; both read `VOKOMA_CONFIG` and can run while the
server is up. `/api/server` is the public liveness endpoint. SIGTERM and SIGINT close
listeners and SQLite cleanly.

```sh
pnpm check          # formatting, lint, types, tests, contract freshness, build
pnpm format        # format server sources
pnpm openapi       # regenerate ../contracts/openapi.json after route/schema changes
```

Individual commands are `format:check`, `lint`, `typecheck`, `test`,
`openapi:check`, and `build`. The committed contract is generated without loading
real configuration or touching the media library. Runtime zod schemas validate JSON
requests and responses. File bytes are served by Node in M0 (`sendContent`), bypassing
JSON serialization. One byte range is honoured, including open-ended and suffix
ranges; a Range header that does not parse, uses another unit or asks for several
ranges is ignored and the whole file is sent with 200 (RFC 9110). Unsatisfiable
ranges return 416. HEAD ignores Range. If a file shrinks mid-transfer the connection
is closed rather than left waiting.

Metadata shapes are described in `docs/milestones/M0.md`. Folder listing only
returns duration when a cached probe matches path, size and nanosecond modification
time; it never probes. A cold listing stats every entry first and then writes new or
changed rows in one transaction. Stable opaque file IDs persist in SQLite. Renames
create new IDs. Entries whose name starts with a dot or is not valid UTF-8 are not
listed; an entry that cannot be opened is skipped with a warning in the log.

Symlinks are followed when the file they resolve to is inside the root; anything that
resolves outside is refused (and omitted from listings). Containment is checked on
the opened descriptor's real path. Paths are POSIX relative paths, without parent
traversal or backslashes. Media names preserve Unicode and punctuation. ffprobe uses
a read-only inherited descriptor, has a 30-second limit and an 8 MiB output limit,
and cannot access network protocols. Concurrent requests for one file share a probe
and at most three probes run at once. Probe failures return a sanitized 422; API
responses never reveal paths. Unexpected failures return 500 `internal_error` and
are logged in full in the server log.

Build from the repository root with
`docker build -f server/Dockerfile -t vokoma:local .`.
The runtime image includes Debian's ffprobe and its linked libraries; ffmpeg is
only needed on the host for generated test fixtures.
The slim image carries ffprobe's libraries without Debian package records.
Image vulnerability scanners that rely on those records will not see these libraries.
M0 runs one container (`api`). Copy
`deploy/compose.example.yaml` and replace its example mounts/config; create the
writable data directory first. `docker compose -f deploy/compose.example.yaml up
--build` starts it. Media mounts are read
only and only the API port is published, on loopback for a reverse proxy.

No scanning jobs, series/broadcast model, recorder behavior, encoding jobs, sync,
watch tracking, downloads, web player or nginx deployment are included. The
real-device engine gate is the next M0 part.

## Published images and manual updates

The release workflow publishes `ghcr.io/alb11747/vokoma-server:nightly`, immutable
versioned release tags, and `stable` on stable tags. Configure the Compose
service's image to that address instead of a local build. Stop playback before a
restart; M0 has no server self-update or automatic idle detection.

```sh
# Use the Compose file you configured for deployment.
docker compose pull
docker compose up -d --no-build
docker compose ps
docker compose logs --tail=50
```

Check GET /api/server through the configured endpoint after restarting. To roll
back, set the image to the previous version, pull and repeat up. Persist
the configured database directory across container replacements.

SQLite schema versions are tracked in `user_version`. Startup applies ordered,
transactional migrations and refuses databases newer than the code. Existing
unversioned M0 databases receive version 1 through the same idempotent table
creation used for fresh databases. Before changing an existing database, SQLite
makes a consistent file copy (including committed WAL data) at `vokoma.sqlite.bak`.
Only the latest completed backup is retained. Keep enough free space for that copy;
a backup failure prevents migration. Stop the server before restoring a backup,
and preserve/remove any SQLite WAL/SHM sidecars together with the replaced database.

Published images set the runtime package version with the `VOKOMA_VERSION` build
argument. Local builds default to `0.0.0`; source package metadata and the committed
OpenAPI contract remain unchanged. To test a built image with generated MKV, MP4
and MPEG-TS fixtures (H.264, HEVC, AV1, AAC, FLAC, Opus and ASS), run:

```sh
# From server/, with Docker and host ffmpeg available.
IMAGE=vokoma:local EXPECTED_VERSION=0.0.0 node --test test/image.test.mjs
```

This checks the actual image as non-root with a read-only root filesystem and a
writable temporary data directory, including `/api/server` and OpenAPI versions.

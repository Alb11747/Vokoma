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
remote access. Forwarded IP headers are not trusted; behind a proxy the login limit
is shared by the proxy's clients. The limiter allows five attempts per minute per
peer, including successful logins.

Configuration is JSON. Environment overrides are `VOKOMA_CONFIG`, `VOKOMA_HOST`,
`VOKOMA_PORT`, `VOKOMA_DATA_DIRECTORY`, `VOKOMA_USERNAME`, `VOKOMA_PASSWORD_HASH`,
`VOKOMA_TOKEN_SECRET`, `VOKOMA_TOKEN_SECRET_FILE`, and `VOKOMA_ROOTS` (a JSON array).
The inline secret override wins over a key file. Keep secrets out of shell history.
Keep the data directory outside media roots, owned by the process user. Container
bind mounts need permissions for the image's `node` user (UID 1000).

Access tokens last 15 minutes. Refresh tokens expire after 30 days without refresh,
rotate on use, and are stored only as SHA-256 hashes. Logout immediately revokes
both token types for that device. Already running byte transfers finish normally.
There is no device-management UI or remote device-revocation route in the M0 API.

`pnpm build` produces `dist/`; run `node dist/main.js api`, `recorder`, or `worker`.
The latter two only log their idle status and expose `/health`. The API's `/health`
requires authentication; `/api/server` is its public liveness endpoint. SIGTERM and
SIGINT close listeners and SQLite cleanly.

```sh
pnpm check          # formatting, lint, types, tests, contract freshness, build
pnpm format        # format server sources
pnpm openapi       # regenerate ../contracts/openapi.json after route/schema changes
```

Individual commands are `format:check`, `lint`, `typecheck`, `test`,
`openapi:check`, and `build`. The committed contract is generated without loading
real configuration or touching the media library. Runtime zod schemas validate JSON
requests and responses. File bytes bypass JSON serialization. Single byte ranges
support open-ended and suffix requests; malformed, multiple and unsatisfiable ranges
return 416. HEAD ignores Range and reports the full representation's size.
`NodeContentSender` is the small boundary for future nginx transfer delegation.

M0 does not define nested metadata types. This implementation uses nullable video
and duration, ffprobe's container name, stream indexes, codec/language/title/default/
forced track fields, video dimensions/pixel format/frame rate, audio channels/sample
rate, and chapters with startMs/endMs/title. Missing metadata is null. The generated
OpenAPI contract gives the exact shapes. Folder listing only returns duration when a
cached probe matches path, size and nanosecond modification time; it never probes.
Stable opaque file IDs persist in SQLite. Renames create new IDs.

All symlinks are refused, including links inside a root; symlinks are omitted from
listings. Paths are POSIX relative paths, without parent traversal or backslashes.
The configured root itself may resolve through a symlink. Media names preserve
Unicode and punctuation. ffprobe uses a read-only inherited descriptor, has a 30-second
limit and an 8 MiB output limit, and cannot access network protocols. Probe failures
return a sanitized error; diagnostics never reveal private paths in API responses or
logs. Invalid or unsupported media can be listed but returns 422 when probing fails.

Build from the repository root with
`docker build -f server/Dockerfile -t vokoma:local .`.
The image includes ffmpeg, ffprobe and streamlink; one image runs all three entry
points. Copy `deploy/compose.example.yaml` and replace its example mounts/config;
create the writable data directory first. `docker compose -f
deploy/compose.example.yaml up --build` starts the services. Media mounts are read
only and only the API port is published, on loopback for a reverse proxy.

No scanning jobs, series/broadcast model, recorder behavior, encoding jobs, sync,
watch tracking, downloads, web player, nginx deployment or image publishing are
included. Client releases, updates and the real-device engine gate are later M0 parts.

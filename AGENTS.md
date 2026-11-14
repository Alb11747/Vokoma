# Vokoma — agent guide

Vokoma is one person's media player for anime and Twitch stream recordings: a server on
their home machine, and one client app for Windows, Android and web (iOS and macOS
later). The repo is public.

Read first, in this order:
1. [docs/PLAN.md](docs/PLAN.md) — what the app must do. It is the source of truth.
2. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how it is built, and why.
3. The current milestone file under [docs/milestones/](docs/milestones/).

If your task conflicts with PLAN.md or ARCHITECTURE.md, stop and report the conflict
to whoever gave you the task. Do not resolve it by quietly changing either side.

## Layout

```
apps/client/     Flutter app (Dart). Playback goes through lib/engine/PlayerEngine only.
server/          TypeScript server (Node). One codebase, three entry points.
contracts/       OpenAPI document generated from the server; the Dart client is generated from it.
tools/           Small standalone tools (engine benchmark, importers).
deploy/          Compose file and nginx config.
docs/            PLAN.md, ARCHITECTURE.md, milestones/. docs/private/ is not in Git.
```

## Rules that are easy to break

- **Nothing private in Git.** No host names, addresses, home-directory paths, channel
  names, account names or tokens, in code, tests, fixtures, docs or commit messages.
  Deployment values come from configuration. Private notes live in `docs/private/`,
  which is ignored.
- **Never modify, move or delete media files** outside the code paths PLAN.md defines
  for it (recycle bin, archive replacement), and never from a test. Tests use generated
  fixtures, not the real library.
- **Credentials go in headers, never in URLs,** logs or saved playlists.
- **Player code talks to `PlayerEngine`,** never to mpv or `<video>` directly. Anything
  mpv-specific stays inside `MpvEngine`.
- **Disk space is tight** on the development and server machines. Keep SDKs and build
  caches in one place, report their size when you add one, and clean build output you
  no longer need.
- **Don't hide failures.** No swallowed errors, weakened checks or skipped tests to get
  a green run.

## Working here

- Conventional Commits (`feat(server): …`, `fix(client): …`). Credit each contributing
  model in `Co-Authored-By` trailers.
- Work on a branch in a worktree and open a pull request; `main` is released
  automatically, so it must always build.
- Before pushing, run the checks for the part you touched. Each part documents its own
  commands in its README (`server/README.md`, `apps/client/README.md`).
- Keep changes scoped to the task. Propose anything larger instead of building it.
- Substantial code gets an independent review before merge.

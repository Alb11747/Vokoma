import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import {
  mkdtemp,
  mkdir,
  writeFile,
  symlink,
  open,
  readFile,
  utimes,
  rm,
  rename,
  chmod,
  truncate,
  readdir,
} from "node:fs/promises";
import http from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import argon2 from "argon2";
import { SignJWT } from "jose";
import { openDatabase } from "../src/db.js";
import { buildApp } from "../src/app.js";
import { loadConfig, type Config } from "../src/config.js";
let scratch: string,
  root: string,
  app: Awaited<ReturnType<typeof buildApp>>,
  config: Config;
let headers: { authorization: string };
const login = () =>
  app.inject({
    method: "POST",
    url: "/api/auth/login",
    payload: {
      username: "placeholder",
      password: "test-password",
      deviceName: "test",
      platform: "test",
    },
  });
const list = (folder = "") =>
  app.inject({
    url: `/api/roots/media/entries?path=${encodeURIComponent(folder)}`,
    headers,
  });
before(async () => {
  scratch = await mkdtemp(path.join(tmpdir(), "vokoma-test-"));
  root = path.join(scratch, "media");
  await mkdir(root);
  await mkdir(path.join(root, "Folder 10"));
  await mkdir(path.join(root, "Folder 2"));
  const fixture = path.join(root, "[Example] 😀 全角： episode 2.mkv");
  const subtitle = path.join(scratch, "subtitle.srt");
  await writeFile(subtitle, "1\n00:00:00,000 --> 00:00:00,500\nFixture\n");
  const chapters = path.join(scratch, "chapters.txt");
  await writeFile(
    chapters,
    ";FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=500\ntitle=Example chapter\n",
  );
  execFileSync("ffmpeg", [
    "-v",
    "error",
    "-f",
    "lavfi",
    "-i",
    "color=size=32x32:rate=10",
    "-f",
    "lavfi",
    "-i",
    "sine=frequency=440",
    "-i",
    subtitle,
    "-i",
    chapters,
    "-map",
    "0:v",
    "-map",
    "1:a",
    "-map",
    "2:s",
    "-map_metadata",
    "3",
    "-t",
    "1",
    "-c:v",
    "mpeg4",
    "-c:a",
    "aac",
    "-c:s",
    "srt",
    "-metadata:s:a:0",
    "language=eng",
    fixture,
  ]);
  execFileSync("ffmpeg", [
    "-v",
    "error",
    "-i",
    fixture,
    "-map",
    "0:v",
    "-map",
    "0:a",
    "-c",
    "copy",
    path.join(root, "episode 10.mp4"),
  ]);
  execFileSync("ffmpeg", [
    "-v",
    "error",
    "-i",
    fixture,
    "-map",
    "0:v",
    "-map",
    "0:a",
    "-c:v",
    "mpeg2video",
    "-c:a",
    "copy",
    path.join(root, "Folder 2", "sample.ts"),
  ]);
  await writeFile(path.join(root, "empty.ts"), "");
  await writeFile(path.join(root, "hidden.nfo"), "private");
  await writeFile(
    path.join(root, "a".repeat(240) + ".mkv"),
    await readFile(fixture),
  );
  await writeFile(path.join(scratch, "outside.mp4"), "outside");
  await symlink(
    path.join(scratch, "outside.mp4"),
    path.join(root, "escape.mp4"),
  );
  await symlink(scratch, path.join(root, "escape"));
  // Folder 10 holds entries that must not break a listing, and symlinks that stay inside.
  const odd = path.join(root, "Folder 10");
  await writeFile(
    Buffer.concat([
      Buffer.from(odd + "/bad "),
      Buffer.from([0xff, 0xfe]),
      Buffer.from(".mkv"),
    ]),
    "x",
  );
  await writeFile(path.join(odd, "locked.mkv"), "x");
  await chmod(path.join(odd, "locked.mkv"), 0);
  await writeFile(path.join(odd, ".hidden.mkv"), "x");
  await mkdir(path.join(odd, ".hidden folder"));
  await symlink("../Folder 2", path.join(odd, "linked folder"));
  await symlink("../Folder 2/sample.ts", path.join(odd, "linked.ts"));
  await symlink("missing.mkv", path.join(odd, "dangling.mkv"));
  // ffprobe reports a Matroska cover attachment as a video stream marked attached_pic.
  const cover = path.join(scratch, "cover.jpg");
  execFileSync("ffmpeg", [
    "-v",
    "error",
    "-f",
    "lavfi",
    "-i",
    "color=size=16x16",
    "-frames:v",
    "1",
    cover,
  ]);
  execFileSync("ffmpeg", [
    "-v",
    "error",
    "-i",
    fixture,
    "-map",
    "0:a",
    "-c",
    "copy",
    "-attach",
    cover,
    "-metadata:s:t",
    "mimetype=image/jpeg",
    path.join(odd, "cover.mkv"),
  ]);
  const big = await open(path.join(root, "large.ts"), "w");
  await big.truncate(2 ** 32 + 7);
  await big.write(Buffer.from("END"), 0, 3, 2 ** 32 + 4);
  await big.close();
  config = {
    listen: { host: "127.0.0.1", port: 3000 },
    trustProxy: false,
    dataDirectory: path.join(scratch, "data"),
    account: {
      username: "placeholder",
      passwordHash: await argon2.hash("test-password", {
        type: argon2.argon2id,
      }),
    },
    tokenSecret: "test-secret-only-for-generated-fixtures",
    roots: [{ id: "media", name: "Media", kind: "anime", path: root }],
  };
  app = await buildApp(config);
  const res = await login();
  assert.equal(res.statusCode, 200);
  headers = { authorization: `Bearer ${res.json().accessToken}` };
});
after(async () => {
  await app?.close();
  if (scratch) await rm(scratch, { recursive: true, force: true });
});
test("public server, auth required everywhere else, validation and error shape", async () => {
  assert.equal((await app.inject("/api/server")).json().apiVersion, 1);
  for (const url of [
    "/api/roots",
    "/api/files/unknown",
    "/api/files/unknown/content",
  ])
    assert.equal((await app.inject(url)).statusCode, 401);
  const invalid = await app.inject({
    method: "POST",
    url: "/api/auth/login",
    payload: { password: "x" },
  });
  assert.equal(invalid.statusCode, 400);
  assert.equal(invalid.json().error.code, "invalid_request");
  const large = await app.inject({
    method: "POST",
    url: "/api/auth/login",
    payload: { password: "x".repeat(20_000) },
  });
  assert.equal(large.statusCode, 413);
  assert.equal(large.json().error.code, "payload_too_large");
  const wrong = await app.inject({
    method: "POST",
    url: "/api/auth/login",
    payload: {
      username: "placeholder",
      password: "wrong",
      deviceName: "test",
      platform: "test",
    },
  });
  assert.equal(wrong.statusCode, 401);
  const expired = await new SignJWT({})
    .setProtectedHeader({ alg: "HS256" })
    .setIssuer("vokoma")
    .setAudience("vokoma-api")
    .setSubject("test")
    .setExpirationTime(1)
    .sign(new TextEncoder().encode(config.tokenSecret));
  assert.equal(
    (
      await app.inject({
        url: "/api/roots",
        headers: { authorization: `Bearer ${expired}` },
      })
    ).statusCode,
    401,
  );
  assert.equal(
    (await app.inject({ url: "/api/roots?accessToken=anything" })).statusCode,
    401,
  );
});
test("benchmark uploads need auth, are size-limited, saved with safe names and pruned", async () => {
  const upload = (payload: unknown, auth: object | undefined = headers) =>
    app.inject({
      method: "POST",
      url: "/api/diagnostics/benchmark",
      headers: auth,
      payload: payload as object,
    });
  const diagnostics = path.join(config.dataDirectory, "diagnostics");
  const content = '{"schema":1}\n{"schema":1}\n';
  assert.equal(
    (await upload({ device: "x", appVersion: "1", content }, {})).statusCode,
    401,
  );
  for (const bad of [
    {},
    { device: "x", appVersion: "1", content: "" },
    { device: "x", appVersion: "1", content: " \n" },
    { device: "", appVersion: "1", content },
  ])
    assert.equal((await upload(bad)).statusCode, 400);
  const tooLarge = await upload({
    device: "x",
    appVersion: "1",
    content: "x".repeat(17 * 1024 * 1024),
  });
  assert.equal(tooLarge.statusCode, 413);
  assert.equal(tooLarge.json().error.code, "payload_too_large");
  // Larger than the default limit for other routes, within this route's.
  const big = "y".repeat(2 * 1024 * 1024);
  const saved = await upload({
    device: "../Pixel 8 / Ünï",
    appVersion: "0.1.0-nightly.5+7",
    content: big,
  });
  assert.equal(saved.statusCode, 201);
  const { name } = saved.json() as { name: string };
  assert.match(
    name,
    /^benchmark-\d{8}T\d{6}\.\d{3}Z-Pixel-8-n-0\.1\.0-nightly\.5-7-[0-9a-f]{6}\.jsonl$/,
  );
  assert.equal(await readFile(path.join(diagnostics, name), "utf8"), big);
  const names = [];
  for (let i = 0; i < 21; i++) {
    const res = await upload({ device: "d", appVersion: "1", content });
    assert.equal(res.statusCode, 201);
    names.push((res.json() as { name: string }).name);
  }
  // The newest 20 remain; the 2 MB upload was the oldest and is gone.
  assert.deepEqual((await readdir(diagnostics)).sort(), names.slice(1).sort());
});
test("refresh rotates, the previous token works for 60 s, and logout revokes only this device", async () => {
  const first = (await login()).json(),
    second = (await login()).json();
  const refresh = (refreshToken: string) =>
    app.inject({
      method: "POST",
      url: "/api/auth/refresh",
      payload: { refreshToken },
    });
  // A lost response or a concurrent retry gets the same rotated token.
  const results = await Promise.all([
    refresh(first.refreshToken),
    refresh(first.refreshToken),
  ]);
  assert.deepEqual(
    results.map((r) => r.statusCode),
    [200, 200],
  );
  const rotated = results[0]!.json();
  assert.equal(rotated.deviceId, first.deviceId);
  assert.notEqual(rotated.refreshToken, first.refreshToken);
  assert.equal(results[1]!.json().refreshToken, rotated.refreshToken);
  // Once the new token has been used, the old one no longer works.
  const next = (await refresh(rotated.refreshToken)).json();
  assert.equal((await refresh(first.refreshToken)).statusCode, 401);
  // After the grace period the previous token is refused.
  const db = openDatabase(path.join(config.dataDirectory, "vokoma.sqlite"));
  try {
    db.prepare("UPDATE device SET previous_refresh_until=? WHERE id=?").run(
      Date.now() - 1,
      first.deviceId,
    );
  } finally {
    db.close();
  }
  assert.equal((await refresh(rotated.refreshToken)).statusCode, 401);
  assert.equal((await refresh(next.refreshToken)).statusCode, 200);
  assert.equal(
    (
      await app.inject({
        method: "POST",
        url: "/api/auth/logout",
        headers: { authorization: `Bearer ${rotated.accessToken}` },
      })
    ).statusCode,
    204,
  );
  assert.equal(
    (
      await app.inject({
        url: "/api/roots",
        headers: { authorization: `Bearer ${first.accessToken}` },
      })
    ).statusCode,
    401,
  );
  assert.equal(
    (
      await app.inject({
        method: "POST",
        url: "/api/auth/refresh",
        payload: { refreshToken: next.refreshToken },
      })
    ).statusCode,
    401,
  );
  assert.equal(
    (
      await app.inject({
        url: "/api/roots",
        headers: { authorization: `Bearer ${second.accessToken}` },
      })
    ).statusCode,
    200,
  );
});
test("one bad entry does not break a listing; symlinks inside the root work", async () => {
  const res = await list("Folder 10/");
  assert.equal(res.statusCode, 200);
  assert.equal(res.json().path, "Folder 10");
  const names = res.json().entries.map((e: { name: string }) => e.name);
  // locked.mkv is readable anyway when the tests run as root.
  const expected = ["linked folder", "cover.mkv", "linked.ts"];
  if (process.getuid?.() !== 0) assert.deepEqual(names, expected);
  else
    assert.deepEqual(
      names.filter((n: string) => n !== "locked.mkv"),
      expected,
    );
  assert.equal((await list("Folder 10/linked folder")).statusCode, 200);
  const linked = res
    .json()
    .entries.find((e: { name: string }) => e.name === "linked.ts");
  assert.equal(
    (await app.inject({ url: `/api/files/${linked.fileId}/content`, headers }))
      .statusCode,
    200,
  );
  assert.equal((await list("./Folder 2//")).json().path, "Folder 2");
});
test("cover art is not chosen as the video stream", async () => {
  const cover = (await list("Folder 10"))
    .json()
    .entries.find((e: { name: string }) => e.name === "cover.mkv");
  const data = (
    await app.inject({ url: `/api/files/${cover.fileId}`, headers })
  ).json();
  assert.equal(data.audioTracks.length, 1);
  assert.equal(data.video, null);
});
test("concurrent probes of one file share one ffprobe run; a missing ffprobe is a 500", async () => {
  await writeFile(
    path.join(root, "Folder 2", "copy.ts"),
    await readFile(path.join(root, "Folder 2", "sample.ts")),
  );
  await writeFile(
    path.join(root, "Folder 2", "copy 2.ts"),
    await readFile(path.join(root, "Folder 2", "sample.ts")),
  );
  const entries = (await list("Folder 2")).json().entries;
  const id = (name: string) =>
    entries.find((e: { name: string }) => e.name === name).fileId;
  const bin = path.join(scratch, "bin"),
    calls = path.join(scratch, "ffprobe-calls");
  await mkdir(bin);
  const real = execFileSync("sh", ["-c", "command -v ffprobe"], {
    encoding: "utf8",
  }).trim();
  await writeFile(
    path.join(bin, "ffprobe"),
    `#!/bin/sh\necho run >> '${calls}'\nexec '${real}' "$@"\n`,
    { mode: 0o755 },
  );
  const previousPath = process.env.PATH;
  try {
    process.env.PATH = bin;
    const results = await Promise.all(
      Array.from({ length: 10 }, () =>
        app.inject({ url: `/api/files/${id("copy.ts")}`, headers }),
      ),
    );
    assert.deepEqual(new Set(results.map((r) => r.statusCode)), new Set([200]));
    assert.equal(
      (await readFile(calls, "utf8")).split("\n").filter(Boolean).length,
      1,
    );
    process.env.PATH = "";
    const missing = await app.inject({
      url: `/api/files/${id("copy 2.ts")}`,
      headers,
    });
    assert.equal(missing.statusCode, 500);
    assert.equal(missing.json().error.code, "internal_error");
  } finally {
    process.env.PATH = previousPath;
  }
});
test("natural listing hides nonmedia, empty files and symlinks; probes are lazy and cached", async () => {
  const res = await list();
  assert.equal(res.statusCode, 200);
  const entries = res.json().entries;
  assert.deepEqual(
    entries.slice(0, 2).map((e: { name: string }) => e.name),
    ["Folder 2", "Folder 10"],
  );
  assert.ok(
    !entries.some((e: { name: string }) => /escape|hidden|empty/.test(e.name)),
  );
  const file = entries.find((e: { name: string }) => e.name.includes("😀"));
  assert.ok(file);
  assert.equal(file.durationMs, undefined);
  const metadata = await app.inject({
    url: `/api/files/${file.fileId}`,
    headers,
  });
  assert.equal(metadata.statusCode, 200);
  const data = metadata.json();
  assert.equal(data.fileId, file.fileId);
  assert.ok(data.durationMs >= 1000);
  assert.equal(data.video.width, 32);
  assert.equal(data.audioTracks[0].language, "eng");
  assert.equal(data.subtitleTracks.length, 1);
  assert.equal(data.chapters[0].title, "Example chapter");
  assert.equal(
    (await list())
      .json()
      .entries.find((e: { fileId: string }) => e.fileId === file.fileId)
      .durationMs,
    data.durationMs,
  );
  const future = new Date(Date.now() + 10_000);
  await utimes(path.join(root, file.name), future, future);
  assert.equal(
    (await list())
      .json()
      .entries.find((e: { fileId: string }) => e.fileId === file.fileId)
      .durationMs,
    undefined,
  );
  assert.equal(
    (await app.inject({ url: `/api/files/${file.fileId}`, headers }))
      .statusCode,
    200,
  );
});
test("MP4 and transport-stream fixtures probe through read-only descriptors", async () => {
  const mp4 = (await list())
    .json()
    .entries.find((entry: { name: string }) => entry.name === "episode 10.mp4");
  const ts = (await list("Folder 2"))
    .json()
    .entries.find((entry: { name: string }) => entry.name === "sample.ts");
  for (const file of [mp4, ts]) {
    const response = await app.inject({
      url: `/api/files/${file.fileId}`,
      headers,
    });
    assert.equal(response.statusCode, 200);
    assert.ok(response.json().durationMs > 0);
    assert.equal(response.json().audioTracks.length, 1);
  }
});

test("a data directory inside a media root is refused before anything is written", async () => {
  const root = config.roots[0]!.path;
  const link = path.join(scratch, "data-link");
  await symlink(root, link);
  for (const dataDirectory of [
    path.join(root, "state", "db"),
    path.join(link, "state"),
  ])
    await assert.rejects(
      buildApp({ ...config, dataDirectory }),
      /outside media roots/,
    );
  await assert.rejects(readFile(path.join(root, "state")), { code: "ENOENT" });
});
test("traversal, absolute paths and symlink escapes refused", async () => {
  for (const folder of [
    "..",
    "../media",
    "/etc",
    "escape",
    "escape/..",
    "Folder 2/../../",
    "..\\",
    "\0",
  ])
    assert.equal((await list(folder)).statusCode, 403, folder);
  assert.equal((await list("missing")).statusCode, 404);
  const files = (await list()).json().entries;
  const id = files.find(
    (e: { name: string }) => e.name === "episode 10.mp4",
  ).fileId;
  // Replace a previously indexed inode with an escape; lookup must recheck it.
  await rename(
    path.join(root, "episode 10.mp4"),
    path.join(scratch, "replaced.mp4"),
  );
  await symlink(
    path.join(scratch, "outside.mp4"),
    path.join(root, "episode 10.mp4"),
  );
  assert.equal(
    (await app.inject({ url: `/api/files/${id}/content`, headers })).statusCode,
    403,
  );
});
test("single, open-ended, suffix and invalid ranges, HEAD, and offsets beyond 4 GB", async () => {
  const entries = (await list()).json().entries;
  const file = entries.find((e: { name: string }) => e.name.includes("😀"));
  const url = `/api/files/${file.fileId}/content`;
  const full = await app.inject({ url, headers });
  assert.equal(full.statusCode, 200);
  assert.equal(full.rawPayload.length, file.sizeBytes);
  for (const [range, start, end] of [
    ["bytes=0-9", 0, 9],
    ["bytes=10-", 10, file.sizeBytes - 1],
    ["bytes=-10", file.sizeBytes - 10, file.sizeBytes - 1],
    ["bytes=0-999999", 0, file.sizeBytes - 1],
  ] as const) {
    const res = await app.inject({ url, headers: { ...headers, range } });
    assert.equal(res.statusCode, 206);
    assert.deepEqual(res.rawPayload, full.rawPayload.subarray(start, end + 1));
    assert.equal(
      res.headers["content-range"],
      `bytes ${start}-${end}/${file.sizeBytes}`,
    );
  }
  const upper = await app.inject({
    url,
    headers: { ...headers, range: "BYTES=0-9" },
  });
  assert.equal(upper.statusCode, 206);
  assert.equal(upper.rawPayload.length, 10);
  // RFC 9110: an invalid, multi-range or other-unit header is ignored.
  for (const range of [
    "bytes=5-2",
    "bytes=0-1,4-5",
    "bytes=-",
    "garbage",
    "items=0-1",
  ]) {
    const res = await app.inject({ url, headers: { ...headers, range } });
    assert.equal(res.statusCode, 200, range);
    assert.equal(res.rawPayload.length, file.sizeBytes, range);
  }
  for (const range of ["bytes=999999-", "bytes=-0"]) {
    const res = await app.inject({ url, headers: { ...headers, range } });
    assert.equal(res.statusCode, 416, range);
    assert.equal(res.headers["content-range"], `bytes */${file.sizeBytes}`);
    assert.equal(res.json().error.code, "invalid_range");
  }
  const head = await app.inject({
    method: "HEAD",
    url,
    headers: { ...headers, range: "bytes=0-9" },
  });
  assert.equal(head.statusCode, 200);
  assert.equal(Number(head.headers["content-length"]), file.sizeBytes);
  assert.equal(head.rawPayload.length, 0);
  const big = entries.find((e: { name: string }) => e.name === "large.ts");
  const res = await app.inject({
    url: `/api/files/${big.fileId}/content`,
    headers: { ...headers, range: `bytes=${2 ** 32 + 4}-` },
  });
  assert.equal(res.statusCode, 206);
  assert.equal(res.body, "END");
  assert.equal(Number(res.headers["content-length"]), 3);
});
test("sessions, opaque IDs and cached probes survive reopening SQLite", async () => {
  const entries = (await list()).json().entries;
  const file = entries.find((entry: { name: string }) =>
    entry.name.includes("😀"),
  );
  const second = await buildApp(config);
  const previousPath = process.env.PATH;
  try {
    const db = openDatabase(path.join(config.dataDirectory, "vokoma.sqlite"));
    try {
      const stored = db
        .prepare("SELECT refresh_hash FROM device LIMIT 1")
        .get() as { refresh_hash: string };
      assert.match(stored.refresh_hash, /^[a-f0-9]{64}$/);
    } finally {
      db.close();
    }
    assert.deepEqual(
      (await second.inject({ url: "/api/roots/media/entries", headers })).json()
        .entries,
      entries,
    );
    process.env.PATH = "";
    const cached = await second.inject({
      url: `/api/files/${file.fileId}`,
      headers,
    });
    assert.equal(cached.statusCode, 200);
    assert.equal(cached.json().fileId, file.fileId);
  } finally {
    process.env.PATH = previousPath;
    await second.close();
  }
});

test("probe failures are explicit and sanitized", async () => {
  await writeFile(path.join(root, "corrupt.mp4"), "invalid media");
  const file = (await list())
    .json()
    .entries.find((entry: { name: string }) => entry.name === "corrupt.mp4");
  const response = await app.inject({
    url: `/api/files/${file.fileId}`,
    headers,
  });
  assert.equal(response.statusCode, 422);
  assert.equal(response.json().error.code, "probe_failed");
  assert.ok(!response.body.includes(scratch));
});

test("login limiter counts only failures per client and clears on success", async () => {
  const attempt = (
    password: string,
    remoteAddress: string,
    forwarded?: string,
    target = app,
  ) =>
    target
      .inject({
        method: "POST",
        url: "/api/auth/login",
        remoteAddress,
        headers: forwarded ? { "x-forwarded-for": forwarded } : {},
        payload: {
          username: "placeholder",
          password,
          deviceName: "test",
          platform: "test",
        },
      })
      .then((r) => r.statusCode);
  const a = "192.0.2.1";
  for (let i = 0; i < 4; i++) assert.equal(await attempt("wrong", a), 401);
  assert.equal(await attempt("test-password", a), 200);
  for (let i = 0; i < 5; i++) assert.equal(await attempt("wrong", a), 401);
  assert.equal(await attempt("wrong", a), 429);
  assert.equal(await attempt("test-password", a), 429);
  // Successful logins do not count; another client is unaffected.
  for (let i = 0; i < 7; i++)
    assert.equal(await attempt("test-password", "192.0.2.2"), 200);
  // Behind a trusted proxy, clients are told apart by X-Forwarded-For.
  const proxied = await buildApp({ ...config, trustProxy: "192.0.2.10" });
  try {
    for (let i = 0; i < 6; i++)
      await attempt("wrong", "192.0.2.10", "198.51.100.1", proxied);
    assert.equal(
      await attempt("wrong", "192.0.2.10", "198.51.100.1", proxied),
      429,
    );
    assert.equal(
      await attempt("test-password", "192.0.2.10", "198.51.100.2", proxied),
      200,
    );
  } finally {
    await proxied.close();
  }
});
test(
  "a file that shrinks during a download closes the connection",
  { timeout: 10_000 },
  async () => {
    const file = path.join(root, "Folder 2", "shrinking.mkv");
    await writeFile(file, Buffer.alloc(8 * 1024 * 1024, 1));
    const id = (await list("Folder 2"))
      .json()
      .entries.find((e: { name: string }) => e.name === "shrinking.mkv").fileId;
    await app.listen({ host: "127.0.0.1", port: 0 });
    const { port } = app.server.address() as { port: number };
    const received = await new Promise<{ bytes: number; complete: boolean }>(
      (resolve, reject) => {
        const req = http.get(
          {
            host: "127.0.0.1",
            port,
            path: `/api/files/${id}/content`,
            headers,
            agent: new http.Agent({ keepAlive: true }),
          },
          (res) => {
            let bytes = 0;
            res.once("data", (chunk: Buffer) => {
              bytes += chunk.length;
              res.pause();
              void truncate(file, 1024).then(() => {
                res.on("data", (c: Buffer) => (bytes += c.length));
                res.resume();
              });
            });
            res.on("error", () => {});
            res.on("close", () => resolve({ bytes, complete: res.complete }));
          },
        );
        req.on("error", reject);
      },
    );
    assert.equal(received.complete, false);
    assert.ok(received.bytes < 8 * 1024 * 1024);
  },
);
test("config loads the token secret from a key file", async () => {
  const file = path.join(scratch, "config.json"),
    keyFile = path.join(scratch, "secret");
  await writeFile(keyFile, config.tokenSecret + "\n");
  await writeFile(
    file,
    JSON.stringify({
      ...config,
      tokenSecret: undefined,
      tokenSecretFile: keyFile,
    }),
  );
  assert.equal((await loadConfig(file)).tokenSecret, config.tokenSecret);
});

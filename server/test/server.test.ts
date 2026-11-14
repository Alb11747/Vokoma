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
} from "node:fs/promises";
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
  const big = await open(path.join(root, "large.ts"), "w");
  await big.truncate(2 ** 32 + 7);
  await big.write(Buffer.from("END"), 0, 3, 2 ** 32 + 4);
  await big.close();
  config = {
    listen: { host: "127.0.0.1", port: 3000 },
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
    "/health",
  ])
    assert.equal((await app.inject(url)).statusCode, 401);
  const invalid = await app.inject({
    method: "POST",
    url: "/api/auth/login",
    payload: { password: "x" },
  });
  assert.equal(invalid.statusCode, 400);
  assert.equal(invalid.json().error.code, "invalid_request");
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
test("refresh rotates once, concurrent replay fails and logout revokes only this device", async () => {
  const first = (await login()).json(),
    second = (await login()).json();
  const refresh = () =>
    app.inject({
      method: "POST",
      url: "/api/auth/refresh",
      payload: { refreshToken: first.refreshToken },
    });
  const results = await Promise.all([refresh(), refresh()]);
  assert.deepEqual(results.map((r) => r.statusCode).sort(), [200, 401]);
  const rotated = results.find((r) => r.statusCode === 200)!.json();
  assert.equal(rotated.deviceId, first.deviceId);
  assert.notEqual(rotated.refreshToken, first.refreshToken);
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
        payload: { refreshToken: rotated.refreshToken },
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
  for (const range of [
    "bytes=999999-",
    "bytes=5-2",
    "bytes=-0",
    "bytes=0-1,4-5",
    "bytes=-",
    "garbage",
  ]) {
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

test("configuration refuses database writes inside a media root", async () => {
  await assert.rejects(
    buildApp({ ...config, dataDirectory: path.join(root, "database") }),
    /outside media roots/,
  );
});

test("login limiter returns 429", async () => {
  let res;
  for (let i = 0; i < 6; i++) res = await login();
  assert.equal(res!.statusCode, 429);
});
test("config loads a key file and environment overrides", async () => {
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
  process.env.VOKOMA_PORT = "4321";
  try {
    const loaded = await loadConfig(file);
    assert.equal(loaded.listen.port, 4321);
    assert.equal(loaded.tokenSecret, config.tokenSecret);
  } finally {
    delete process.env.VOKOMA_PORT;
  }
});

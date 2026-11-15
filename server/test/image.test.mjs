// Run after docker build: node --test test/image.test.mjs
// Requires host ffmpeg; tests only generated fixtures, in a non-root read-only image.
import process from "node:process";
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

test("runtime image probes supported media and reports its stamped version", () => {
  const dir = mkdtempSync(join(tmpdir(), "vokoma-image-"));
  try {
    const subtitle = join(dir, "subtitle.srt");
    writeFileSync(subtitle, "1\n00:00:00,000 --> 00:00:00,500\nFixture\n");
    const fixtures = [];
    for (const [extension, video, audio, subtitles] of [
      ["mkv", "libx264", "flac", true],
      ["mkv", "libx265", "libopus", true],
      ["mkv", "libaom-av1", "aac", true],
      ["mp4", "libx264", "aac", false],
      ["ts", "libx264", "aac", false],
    ]) {
      const name = `${video}.${extension}`;
      const file = join(dir, name);
      execFileSync("ffmpeg", [
        "-v",
        "error",
        "-f",
        "lavfi",
        "-i",
        "color=size=64x64:rate=10",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=440",
        ...(subtitles ? ["-i", subtitle] : []),
        "-t",
        "0.5",
        "-c:v",
        video,
        "-threads",
        "1",
        ...(video === "libx265"
          ? ["-x265-params", "pools=none:frame-threads=1:log-level=error"]
          : []),
        ...(video === "libaom-av1" ? ["-cpu-used", "8"] : []),
        "-c:a",
        audio,
        ...(subtitles ? ["-c:s", "ass"] : []),
        file,
      ]);
      fixtures.push({
        name,
        bytes: readFileSync(file).toString("base64"),
        video: { libx264: "h264", libx265: "hevc", "libaom-av1": "av1" }[video],
        audio: { flac: "flac", libopus: "opus", aac: "aac" }[audio],
        subtitles,
      });
    }
    const script = `
      import assert from 'node:assert/strict';
      import {execFileSync} from 'node:child_process';
      import {mkdir, writeFile, open} from 'node:fs/promises';
      import {buildApp} from './dist/app.js';
      import {openDatabase} from './dist/db.js';
      import {probe} from './dist/media/probe.js';
      assert.notEqual(process.getuid(), 0);
      execFileSync('ffprobe',['-version']);
      await mkdir('/tmp/media');
      const app = await buildApp({listen:{host:'127.0.0.1',port:3000},trustProxy:false,
        dataDirectory:'/tmp/data', account:{username:'fixture',passwordHash:'fixture'},
        tokenSecret:'fixture-secret-at-least-thirty-two-characters',roots:[]});
      try {
        const response = await app.inject('/api/server');
        assert.equal(response.statusCode,200);
        assert.equal(response.json().version, ${JSON.stringify(process.env.EXPECTED_VERSION ?? "0.0.0")});
        assert.equal(app.swagger().info.version, response.json().version);
        const db = openDatabase(':memory:');
        try {
          for (const f of ${JSON.stringify(fixtures)}) {
            const path = '/tmp/media/'+f.name;
            await writeFile(path,Buffer.from(f.bytes,'base64'));
            const handle = await open(path,'r');
            try {
              const row = {id:f.name,root_id:'fixture',path:f.name,size:0,mtime:'0',probe:null};
              const result = await probe(db,row,handle);
              assert.equal(result.video.codec,f.video);
              assert.equal(result.audioTracks[0].codec,f.audio);
              if(f.subtitles) assert.equal(result.subtitleTracks[0].codec,'ass');
            } finally {await handle.close();}
          }
        } finally {db.close();}
      } finally {await app.close();}
    `;
    const output = execFileSync(
      "docker",
      [
        "run",
        "--rm",
        "-i",
        "--network=none",
        "--read-only",
        "--tmpfs",
        "/tmp:rw,noexec,nosuid,size=32m",
        "--entrypoint",
        "node",
        process.env.IMAGE ?? "vokoma:check",
        "--input-type=module",
        "-",
      ],
      { input: script, encoding: "utf8" },
    );
    assert.equal(output, "");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

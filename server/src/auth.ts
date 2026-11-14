import { createHash, createHmac, randomBytes, randomUUID } from "node:crypto";
import argon2 from "argon2";
import { SignJWT, jwtVerify } from "jose";
import type { Config } from "./config.js";
import type { Database } from "./db.js";
import { HttpError } from "./errors.js";
import { concurrencyLimit } from "./concurrency.js";
const hash = (token: string) =>
  createHash("sha256").update(token).digest("hex");
export class Auth {
  private key: Uint8Array;
  // argon2 verification is memory-hard; cap parallel work on the server.
  private verify = concurrencyLimit(2);
  constructor(
    private db: Database,
    private config: Config,
  ) {
    this.key = new TextEncoder().encode(config.tokenSecret);
  }
  async login(
    input: {
      username: string;
      password: string;
      deviceName: string;
      platform: string;
    },
    ip: string,
  ) {
    const now = Date.now();
    this.db.prepare("DELETE FROM login_limit WHERE reset <= ?").run(now);
    // Count the attempt before verifying, so parallel guesses cannot pass the
    // check together; a correct password clears the count again, so only
    // failures accumulate. A locked peer is refused without verifying.
    const row = this.db
      .prepare(
        "INSERT INTO login_limit VALUES (?,1,?) ON CONFLICT(ip) DO UPDATE SET attempts=attempts+1 RETURNING attempts",
      )
      .get(ip, now + 60_000) as { attempts: number };
    if (row.attempts > 5)
      throw new HttpError(429, "rate_limited", "Try again later");
    const valid = await this.verify(() =>
      argon2.verify(this.config.account.passwordHash, input.password),
    );
    if (input.username !== this.config.account.username || !valid)
      throw new HttpError(401, "invalid_credentials", "Invalid credentials");
    this.db.prepare("DELETE FROM login_limit WHERE ip=?").run(ip);
    const id = randomUUID();
    const refresh = randomBytes(32).toString("base64url");
    this.db
      .prepare(
        "INSERT INTO device(id,name,platform,refresh_hash,refresh_expires) VALUES (?,?,?,?,?)",
      )
      .run(
        id,
        input.deviceName,
        input.platform,
        hash(refresh),
        now + 30 * 86400_000,
      );
    return this.tokens(id, refresh);
  }
  async tokens(id: string, refreshToken: string) {
    const accessToken = await new SignJWT({})
      .setProtectedHeader({ alg: "HS256" })
      .setSubject(id)
      .setIssuer("vokoma")
      .setAudience("vokoma-api")
      .setIssuedAt()
      .setExpirationTime("15m")
      .sign(this.key);
    return { accessToken, expiresInSeconds: 900, refreshToken, deviceId: id };
  }
  async refresh(token: string) {
    // The successor is derived from the presented token, so a client that lost the
    // response can retry with the previous token for 60 s and receive the same new
    // token. Only hashes are stored. A retry never extends the grace period.
    const refresh = createHmac("sha256", this.key)
      .update("refresh:" + token)
      .digest("base64url");
    const now = Date.now();
    const expires = now + 30 * 86400_000;
    // One atomic update ensures simultaneous refreshes cannot both rotate a token.
    const rotated = this.db
      .prepare(
        `UPDATE device SET previous_refresh_hash=refresh_hash, previous_refresh_until=?, refresh_hash=?, refresh_expires=?
         WHERE refresh_hash=? AND revoked=0 AND refresh_expires>? RETURNING id`,
      )
      .get(now + 60_000, hash(refresh), expires, hash(token), now) as
      { id: string } | undefined;
    const row =
      rotated ??
      (this.db
        .prepare(
          `UPDATE device SET refresh_expires=?
           WHERE previous_refresh_hash=? AND refresh_hash=? AND previous_refresh_until>? AND revoked=0 AND refresh_expires>? RETURNING id`,
        )
        .get(expires, hash(token), hash(refresh), now, now) as
        { id: string } | undefined);
    if (!row)
      throw new HttpError(401, "invalid_token", "Invalid refresh token");
    return this.tokens(row.id, refresh);
  }
  async authorize(header: string | undefined) {
    if (!header?.startsWith("Bearer "))
      throw new HttpError(401, "unauthorized", "Bearer token required");
    let id: string | undefined;
    try {
      id = (
        await jwtVerify(header.slice(7), this.key, {
          algorithms: ["HS256"],
          issuer: "vokoma",
          audience: "vokoma-api",
        })
      ).payload.sub;
    } catch {
      throw new HttpError(401, "invalid_token", "Invalid access token");
    }
    if (
      !id ||
      !this.db.prepare("SELECT id FROM device WHERE id=? AND revoked=0").get(id)
    )
      throw new HttpError(401, "invalid_token", "Device revoked");
    return id;
  }
  revoke(id: string) {
    this.db.prepare("UPDATE device SET revoked=1 WHERE id=?").run(id);
  }
}

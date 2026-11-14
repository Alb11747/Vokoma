import { createHash, randomBytes, randomUUID } from "node:crypto";
import argon2 from "argon2";
import { SignJWT, jwtVerify } from "jose";
import type { Config } from "./config.js";
import type { Database } from "./db.js";
import { HttpError } from "./errors.js";
const hash = (token: string) =>
  createHash("sha256").update(token).digest("hex");
export class Auth {
  private key: Uint8Array;
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
    const row = this.db
      .prepare(
        "INSERT INTO login_limit VALUES (?,1,?) ON CONFLICT(ip) DO UPDATE SET attempts=attempts+1 RETURNING attempts",
      )
      .get(ip, now + 60_000) as { attempts: number };
    if (row.attempts > 5)
      throw new HttpError(429, "rate_limited", "Try again later");
    const valid = await argon2.verify(
      this.config.account.passwordHash,
      input.password,
    );
    if (input.username !== this.config.account.username || !valid)
      throw new HttpError(401, "invalid_credentials", "Invalid credentials");
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
    const refresh = randomBytes(32).toString("base64url");
    // One atomic update ensures simultaneous refreshes cannot both consume a token.
    const row = this.db
      .prepare(
        "UPDATE device SET refresh_hash=?,refresh_expires=? WHERE refresh_hash=? AND revoked=0 AND refresh_expires>? RETURNING id",
      )
      .get(
        hash(refresh),
        Date.now() + 30 * 86400_000,
        hash(token),
        Date.now(),
      ) as { id: string } | undefined;
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

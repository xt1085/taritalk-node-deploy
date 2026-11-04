import { test } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";
import { openTestDatabase } from "./d1-sqlite.mjs";
import { createFakeRateLimiter } from "./fake-rate-limit.mjs";

const BASE = "https://taritalk-nodes-submit.taritalk-status.workers.dev";
const VALID = {
  schema_version: 2,
  network: "mainnet",
  public_ip: "1.2.3.4",
  p2p_port: 18189,
  minotari_version: "6.0.0",
  installer_version: "0.1.0",
};

function submit(env, sourceIp, body = VALID) {
  const headers = { "content-type": "application/json" };
  if (sourceIp !== null) headers["cf-connecting-ip"] = sourceIp;
  return worker.fetch(new Request(BASE + "/submit", { method: "POST", headers,
    body: typeof body === "string" ? body : JSON.stringify(body) }), env);
}

async function rows(db) {
  const { results } = await db.prepare("SELECT source_ip, public_ip, review_status FROM submissions ORDER BY rowid").all();
  return results.map((row) => ({ ...row }));
}

// setup: an isolated database and a limiter whose clock the test moves.
function setup() {
  const clock = { now: 0 };
  const limiter = createFakeRateLimiter({ limit: 1, period: 60, now: () => clock.now });
  const db = openTestDatabase();
  return { env: { DB: db, SUBMIT_RATE_LIMIT: limiter }, db, limiter, clock };
}

async function expectLimited(response) {
  assert.equal(response.status, 429);
  assert.equal(response.headers.get("retry-after"), "60");
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.deepEqual(await response.json(), { ok: false, error: "rate_limited" });
}

test("the first valid submission from a source IP is stored once as pending", async () => {
  const { env, db, limiter } = setup();
  const response = await submit(env, "203.0.113.9");
  assert.equal(response.status, 200);
  const answer = await response.json();
  assert.deepEqual(Object.keys(answer).sort(), ["ok", "status", "submission_id"]);
  assert.equal(answer.status, "pending");
  assert.deepEqual(await rows(db), [{ source_ip: "203.0.113.9", public_ip: "1.2.3.4", review_status: "pending" }]);
  assert.deepEqual(limiter.calls, ["203.0.113.9"]);
});

test("a second valid submission from the same source IP inside the period is 429 without a row", async () => {
  const { env, db, limiter } = setup();
  assert.equal((await submit(env, "203.0.113.9")).status, 200);
  await expectLimited(await submit(env, "203.0.113.9"));
  // A changed public_ip or other field does not get around the limit.
  await expectLimited(await submit(env, "203.0.113.9", { ...VALID, public_ip: "5.6.7.8", p2p_port: 18190 }));
  assert.equal((await rows(db)).length, 1);
  assert.deepEqual(limiter.calls, ["203.0.113.9", "203.0.113.9", "203.0.113.9"]);
});

test("a different observed source IP is limited independently", async () => {
  const { env, db } = setup();
  assert.equal((await submit(env, "203.0.113.9")).status, 200);
  await expectLimited(await submit(env, "203.0.113.9"));
  // Same submitted public_ip, other observed source: still accepted.
  assert.equal((await submit(env, "198.51.100.7")).status, 200);
  assert.equal((await submit(env, "2001:db8::7")).status, 200);
  await expectLimited(await submit(env, "198.51.100.7"));
  assert.deepEqual((await rows(db)).map((r) => r.source_ip), ["203.0.113.9", "198.51.100.7", "2001:db8::7"]);
});

test("after the period the same source IP can submit again", async () => {
  const { env, db, clock } = setup();
  assert.equal((await submit(env, "203.0.113.9")).status, 200);
  clock.now = 59;
  await expectLimited(await submit(env, "203.0.113.9"));
  clock.now = 60;
  assert.equal((await submit(env, "203.0.113.9")).status, 200);
  await expectLimited(await submit(env, "203.0.113.9"));
  assert.equal((await rows(db)).length, 2);
});

test("the limit is keyed by the observed source IP, never by the submitted public_ip", async () => {
  const { env, db, limiter } = setup();
  // Two sources submitting the same public_ip: both stored, two keys.
  assert.equal((await submit(env, "203.0.113.9", { ...VALID, public_ip: "1.2.3.4" })).status, 200);
  assert.equal((await submit(env, "203.0.113.10", { ...VALID, public_ip: "1.2.3.4" })).status, 200);
  // One source rotating public_ip: limited after the first.
  await expectLimited(await submit(env, "203.0.113.9", { ...VALID, public_ip: "9.9.9.9" }));
  assert.deepEqual(limiter.calls, ["203.0.113.9", "203.0.113.10", "203.0.113.9"]);
  assert.ok(!limiter.calls.some((k) => k.includes("1.2.3.4") || k.includes("9.9.9.9")));
  assert.equal((await rows(db)).length, 2);
});

test("requests without a readable observed source IP share one conservative key", async () => {
  const { env, db, limiter, clock } = setup();
  assert.equal((await submit(env, null)).status, 200);
  await expectLimited(await submit(env, null));
  // A badly formed header is stored as NULL like a missing one and shares
  // the same slot, so hard-to-attribute requests cannot bypass the limit.
  await expectLimited(await submit(env, "not-an-address"));
  clock.now = 60;
  assert.equal((await submit(env, "not-an-address")).status, 200);
  assert.deepEqual([...new Set(limiter.calls)], ["unknown"]);
  assert.deepEqual((await rows(db)).map((r) => r.source_ip), [null, null]);
});

test("invalid requests keep their responses, never consult the limiter and never store", async () => {
  const { env, db, limiter } = setup();
  const ip = "203.0.113.9";
  const cases = [
    [submit(env, ip, "{not json"), 400, { ok: false, error: "invalid_json" }],
    [submit(env, ip, { ...VALID, public_ip: "10.0.0.1" }), 400, { ok: false, error: "invalid_field", field: "public_ip" }],
    [submit(env, ip, { ...VALID, extra: 1 }), 400, { ok: false, error: "invalid_field", field: "extra" }],
    [submit(env, ip, JSON.stringify({ ...VALID, installer_version: "x".repeat(4096) })), 413, { ok: false, error: "body_too_large" }],
    [worker.fetch(new Request(BASE + "/submit", { method: "POST", headers: { "content-type": "text/plain", "cf-connecting-ip": ip },
      body: JSON.stringify(VALID) }), env), 415, { ok: false, error: "unsupported_media_type" }],
    [worker.fetch(new Request(BASE + "/submit", { method: "GET", headers: { "cf-connecting-ip": ip } }), env), 405,
      { ok: false, error: "method_not_allowed" }],
    [worker.fetch(new Request(BASE + "/submissions", { method: "POST", headers: { "content-type": "application/json",
      "cf-connecting-ip": ip }, body: JSON.stringify(VALID) }), env), 404, { ok: false, error: "not_found" }],
  ];
  for (const [pending, status, body] of cases) {
    const response = await pending;
    assert.equal(response.status, status);
    assert.deepEqual(await response.json(), body);
    assert.equal(response.headers.get("retry-after"), null);
  }
  assert.deepEqual(limiter.calls, []);
  assert.equal((await rows(db)).length, 0);
  // The source is still entitled to its one valid submission afterwards.
  assert.equal((await submit(env, ip)).status, 200);
});

test("a failing rate limiter is a generic error and stores nothing", async () => {
  const db = openTestDatabase();
  const env = { DB: db, SUBMIT_RATE_LIMIT: { async limit() { throw new Error("binding RATELIMIT: internal 0xdead"); } } };
  let response = await submit(env, "203.0.113.9");
  assert.equal(response.status, 500);
  assert.equal(await response.text(), JSON.stringify({ ok: false, error: "rate_limit_error" }));
  // A missing binding fails the same way, closed.
  response = await submit({ DB: db }, "203.0.113.9");
  assert.equal(response.status, 500);
  assert.equal(await response.text(), JSON.stringify({ ok: false, error: "rate_limit_error" }));
  assert.equal((await rows(db)).length, 0);
});

test("the binding in wrangler.toml matches the code: one call per 60 seconds", async () => {
  const { readFileSync } = await import("node:fs");
  const toml = readFileSync(new URL("../wrangler.toml", import.meta.url), "utf8");
  const source = readFileSync(new URL("../src/index.js", import.meta.url), "utf8");
  const block = /\[\[ratelimits\]\]\n((?:[^[\n][^\n]*\n|\n)*)/.exec(toml);
  assert.ok(block, "a [[ratelimits]] table");
  assert.match(block[1], /^name = "SUBMIT_RATE_LIMIT"$/m);
  assert.match(block[1], /^namespace_id = "[1-9][0-9]*"$/m);
  assert.match(block[1], /^simple = \{ limit = 1, period = 60 \}$/m);
  assert.ok(source.includes("env.SUBMIT_RATE_LIMIT.limit("), "the code uses the binding by that name");
  assert.match(source, /^const RATE_LIMIT_PERIOD_SECONDS = 60;$/m, "Retry-After matches the period");
  assert.equal((toml.match(/\[\[ratelimits\]\]/g) || []).length, 1);
});

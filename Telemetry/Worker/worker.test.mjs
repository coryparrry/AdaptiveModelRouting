import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";
import { exportDailyUsage, receive } from "./worker.mjs";

const usageURL = "https://collector.example/v1/used";

/** Runs the migration and D1 statements against real SQLite. */
function fixtureDatabase() {
  const db = new DatabaseSync(":memory:");
  db.exec(readFileSync(new URL("./migrations/0001_usage_counts.sql", import.meta.url), "utf8"));
  /** Mirrors the small D1 prepared-statement surface used by the worker. */
  function prepare(query, params = []) {
    const statement = db.prepare(query);
    return {
      bind: (...args) => prepare(query, args),
      run: () => statement.run(...params),
      all: () => ({ results: statement.all(...params) }),
    };
  }
  return { db, COUNTS: { prepare, batch: (statements) => statements.map((statement) => statement.run()) } };
}

/** Prepares SQLite and an isolated PostHog configuration for a test. */
function fixture(t) {
  const { db, COUNTS } = fixtureDatabase();
  t.after(() => db.close());
  return { db, env: {
    COUNTS,
    PACKAGE_VERSIONS: "0.2.0",
    POSTHOG_PROJECT_TOKEN: "phc_fixture",
    POSTHOG_INGEST_HOST: "https://eu.i.posthog.com",
  } };
}

/** Posts only the version while including a simulated edge IP header. */
function report(env, body, url = usageURL) {
  return receive(new Request(url, {
    method: "POST",
    headers: { "content-type": "text/plain", "cf-connecting-ip": "203.0.113.42" },
    body,
  }), env);
}

test("stores only an atomic daily version total even with simultaneous requests", async (t) => {
  const { db, env } = fixture(t);
  const replies = await Promise.all([report(env, "0.2.0"), report(env, "0.2.0")]);
  assert.deepEqual(replies.map((reply) => reply.status), [204, 204]);
  const rows = db.prepare("SELECT * FROM daily_usage").all();
  assert.equal(rows.length, 1);
  assert.deepEqual({ ...rows[0] }, {
    utc_day: new Date().toISOString().slice(0, 10), package_version: "0.2.0", launches: 2, export_status: 0,
  });
});

test("rejects extra data, oversized bodies, unknown versions, and URLs with queries", async (t) => {
  const { db, env } = fixture(t);
  for (const body of ["", "\uFEFF0.2.0", "0.2.0\nprivate input", "0.2.1", "0".repeat(510)]) {
    assert.equal((await report(env, body)).status, 400);
  }
  assert.equal((await report(env, "0.2.0", usageURL + "?identity=forbidden")).status, 404);
  assert.equal((await receive(new Request(usageURL, {
    method: "POST", headers: { "content-type": "application/json" }, body: "{}",
  }), env)).status, 415);
  assert.equal(db.prepare("SELECT COUNT(*) AS count FROM daily_usage").get().count, 0);
});

test("exports one versioned gauge for a closed day and retries the same point after a temporary failure", async (t) => {
  const { db, env } = fixture(t);
  db.exec(`
    INSERT INTO daily_usage VALUES ('2026-11-19','0.2.0',17,0);
    INSERT INTO daily_usage VALUES (date('now'),'0.2.0',5,0);
  `);
  const payloads = [];
  await assert.rejects(exportDailyUsage(env, async (url, options) => {
    assert.equal(url, "https://eu.i.posthog.com/i/v1/metrics");
    assert.equal(options.headers.Authorization, "Bearer phc_fixture");
    payloads.push(options.body);
    return new Response(null, { status: 503 });
  }), /temporarily rejected/);
  assert.equal(db.prepare("SELECT SUM(export_status) AS status FROM daily_usage").get().status, 0);

  await exportDailyUsage(env, async (_url, options) => {
    payloads.push(options.body);
    const { resourceMetrics } = JSON.parse(options.body);
    const [metric] = resourceMetrics[0].scopeMetrics[0].metrics;
    assert.equal(metric.name, "adaptive_model_routing.usage.daily_launches");
    assert.deepEqual(metric.gauge.dataPoints, [{
      timeUnixNano: "1795132799999000000", asInt: "17",
      attributes: [{ key: "package.version", value: { stringValue: "0.2.0" } }],
    }]);
    return Response.json({});
  });
  assert.equal(payloads[0], payloads[1]);
  assert.equal(db.prepare("SELECT SUM(export_status) AS status FROM daily_usage").get().status, 1);
  await exportDailyUsage(env, () => assert.fail("Already exported or still in progress"));
});

test("keeps rejected points for inspection and continues exporting newer totals", async (t) => {
  const { db, env } = fixture(t);
  db.exec(`
    INSERT INTO daily_usage VALUES ('2026-11-16','0.2.0',1,0);
    INSERT INTO daily_usage VALUES ('2026-11-17','0.2.0',2,0);
    INSERT INTO daily_usage VALUES ('2026-11-18','0.2.0',3,0);
  `);
  const responses = [
    Response.json({ partialSuccess: { rejectedDataPoints: "1" } }),
    new Response(null, { status: 400 }),
    Response.json({}),
  ];
  await exportDailyUsage(env, () => responses.shift());
  assert.deepEqual(db.prepare("SELECT export_status FROM daily_usage ORDER BY utc_day").all()
    .map((row) => row.export_status), [2, 2, 1]);
  await exportDailyUsage(env, () => assert.fail("Permanent rejections must not be retried"));
});

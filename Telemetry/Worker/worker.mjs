const versionPattern = /^(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})$/;
const maxBodyBytes = 14;
const postHogHosts = new Set(["https://eu.i.posthog.com", "https://us.i.posthog.com"]);
const retryableStatuses = new Set([429, 502, 503, 504]);

/** Reads only a short version string and aborts an oversized body, including streamed uploads. */
async function readVersion(body) {
  if (!body) return null;
  const reader = body.getReader();
  const bytes = new Uint8Array(maxBodyBytes);
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      // Preserve any BOM in the decoded string so the version check rejects it.
      if (done) return new TextDecoder("utf-8", { ignoreBOM: true }).decode(bytes.subarray(0, size));
      if (size + value.length > bytes.length) {
        await reader.cancel();
        return null;
      }
      bytes.set(value, size);
      size += value.length;
    }
  } finally {
    reader.releaseLock();
  }
}

/** Counts a version-only report without reading IP headers or storing individual events. */
export async function receive(request, env) {
  const url = new URL(request.url);
  if (url.pathname !== "/v1/used" || url.search || request.method !== "POST") {
    return new Response(null, { status: 404 });
  }
  if (request.headers.get("content-type") !== "text/plain") {
    return new Response(null, { status: 415 });
  }
  const version = await readVersion(request.body);
  if (version === null || !versionPattern.test(version) || !env.PACKAGE_VERSIONS.split(",").includes(version)) {
    return new Response(null, { status: 400 });
  }

  // D1 determines the UTC day at the point of the atomic write. No individual event rows are stored.
  await env.COUNTS.prepare(`
    INSERT INTO daily_usage (utc_day, package_version) VALUES (date('now'), ?)
    ON CONFLICT (utc_day, package_version) DO UPDATE SET launches = launches + 1
  `).bind(version).run();
  return new Response(null, { status: 204 });
}

/** Converts a closed UTC-day total to an OTLP gauge with a stable point timestamp. */
function metricPayload({ utc_day, package_version, launches }) {
  const attributes = [{ key: "service.name", value: { stringValue: "AdaptiveModelRouting" } }];
  const point = {
    timeUnixNano: (BigInt(Date.parse(`${utc_day}T23:59:59.999Z`)) * 1_000_000n).toString(),
    asInt: String(launches),
    attributes: [{ key: "package.version", value: { stringValue: package_version } }],
  };
  return { resourceMetrics: [{
    resource: { attributes },
    scopeMetrics: [{
      scope: { name: "AdaptiveModelRouting" },
      metrics: [{ name: "adaptive_model_routing.usage.daily_launches", unit: "1", gauge: { dataPoints: [point] } }],
    }],
  }] };
}

/** Sends closed-day totals one at a time and retains permanent rejections for inspection. */
export async function exportDailyUsage(env, send = fetch) {
  if (!/^phc_[A-Za-z0-9_-]+$/.test(env.POSTHOG_PROJECT_TOKEN ?? "") || !postHogHosts.has(env.POSTHOG_INGEST_HOST)) {
    return;
  }
  const { results } = await env.COUNTS.prepare(`
    SELECT utc_day, package_version, launches FROM daily_usage
    WHERE utc_day < date('now') AND export_status = 0
    ORDER BY utc_day, package_version LIMIT 16
  `).all();
  const mark = env.COUNTS.prepare("UPDATE daily_usage SET export_status = ? WHERE utc_day = ? AND package_version = ?");
  for (const row of results) {
    const response = await send(`${env.POSTHOG_INGEST_HOST}/i/v1/metrics`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.POSTHOG_PROJECT_TOKEN}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(metricPayload(row)),
      redirect: "error",
      signal: AbortSignal.timeout(10_000),
    });
    if (retryableStatuses.has(response.status)) throw new Error("PostHog temporarily rejected metrics");
    if (!response.ok) {
      await mark.bind(2, row.utc_day, row.package_version).run();
      continue;
    }
    const body = await response.text();
    const acknowledgement = body ? JSON.parse(body) : {};
    const rejected = Number(acknowledgement.partialSuccess?.rejectedDataPoints ?? 0) > 0;
    await mark.bind(rejected ? 2 : 1, row.utc_day, row.package_version).run();
  }
}

export default {
  fetch: receive,
  /** Exports completed UTC days, using the scheduler to retry unchanged gauge points on failure. */
  async scheduled(_event, env) {
    await exportDailyUsage(env);
  },
};

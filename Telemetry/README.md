# Opt-in package usage

One report represents an opted-in app launch in which the router completed at least one foreground request. The report contains only the package version. Cloudflare stores one total per UTC day and package version. PostHog receives the finished daily totals as the metric `adaptive_model_routing.usage.daily_launches`.

The reporting code is an optional SwiftPM product. It starts disabled. Cloudflare receives the HTTPS request and can see the source IP at its edge. The Worker ignores IP and request metadata, stores only the daily counts, and has Worker request logging disabled. The PostHog project token lives in a Worker secret.

## Use from an app

Add the **AdaptiveModelRoutingUsage** product to the app target alongside **AdaptiveModelRouting**. This product first ships in a release after `v0.2.0`. The collector is configured for the proposed `v0.3.0` release. Create one reporter per app process and supply the Worker’s HTTPS URL ending in `/v1/used`. The app obtains consent before enabling reporting and calls `setEnabled(false)` if consent is withdrawn.

```swift
import AdaptiveModelRoutingUsage

// Create and retain one reporter on the main actor during app setup.
let usage = try UsageReporter(
    packageVersion: "0.3.0",
    collectorURL: collectorURL
)
usage.setEnabled(analyticsConsent)

// After a detailed router response, including a streaming .completed result.
if result.status == .completed {
    usage.recordSuccessfulUse()
}
```

Reports from debug builds, simulator builds, previews, or XCTest are excluded. Inference continues immediately. Report submission is best-effort. Daily totals measure accepted reports to the public endpoint and provide an estimate of participating launches.

## Run the collector

The Worker accepts short version strings at `POST /v1/used`. Copy `Worker/wrangler.jsonc` to the ignored `Worker/wrangler.local.jsonc`, set its D1 database ID, and use `--config wrangler.local.jsonc` for migrations and deployment. Keep `PACKAGE_VERSIONS` aligned with the published reporter versions. Set `POSTHOG_INGEST_HOST` to the project’s regional ingestion host and put its `phc_` project token in the `POSTHOG_PROJECT_TOKEN` secret. Use an existing project with Metrics enabled.

The Worker exports completed UTC days every hour and marks them exported after PostHog acknowledges them. Transient failures are retried with the same point timestamp. Permanent rejections are retained in D1 with `export_status = 2` so they can be inspected and requeued after correction.

In PostHog Metrics, filter on service `AdaptiveModelRouting` and group by `package.version`. Use the daily gauge value (or a daily maximum per version) so repeated delivery of the same point does not inflate the count.

## Verify locally

```sh
swift test --filter UsageReporterTests --disable-sandbox
cd Telemetry/Worker
npm ci
npm test
npm run check:bundle
```

The tests use an in-memory SQLite database and a fake PostHog endpoint. [PostHog OTLP settings](https://posthog.com/docs/metrics/installation/other)

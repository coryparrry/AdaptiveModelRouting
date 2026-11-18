# Quota-aware switching verification

The default fastest paired router now confirms a paid promotion when recent matched comparisons disagree with an isolated local slowdown. The numeric weighted latency estimator, model eligibility, and 600-second optional PCC pacing remain unchanged. Two completed comparable pairs provide the recent comparison window; if either found local faster, all of the latest `minimumSamples` local observations must be slower than the latest cloud observation before a cloud preference is promoted. A decisive cloud improvement can therefore promote immediately, while a sustained local slowdown gathers free confirmation.

Pair identifiers and the matched local duration persist on cloud samples, including after local-history pruning. Incomplete or failed comparisons supply no matched evidence. Both provider session buckets and current-request output-size boundaries apply. Concurrent confirmations stay local; authoritative health and policy constraints still take precedence. Explicit quota-conservation opt-out disables the new confirmation.

The measured request-22 regression from the previous real-app run fails before the fix and passes afterward. The fixture contains relative dates and numeric timings, and its counterfactual continuation supplies only the selected local observations. It does not claim to reproduce unobserved future provider timings. New tests also cover owner execution, concurrent calls, successful pair completion orders, incomplete pairs, pruning/reload, both session directions, size boundaries, sustained slowdown, clear cloud wins, repeated cloud wins, and policy/configuration overrides.

Evidence is collected under `.build/quota-switch-stability` (offline) and `.build/live-gui-stable-switch` (actual app). The live acceptance plan is frozen before requests and caps all foreground and optional PCC generations at twelve, with five in the cloud phase. Existing app history is retained. No network changes, provider delays, quota fabrication, or cache seeding are used in the actual app.

An intermittent existing streaming-matrix cleanup assertion occurred during final offline validation: `waitForCalibration` returned while a cancelled synthetic worker still occupied its slot. The isolated 8,640-case matrix passed afterward. The failing log is retained; this follow-up issue is not treated as disproven by a later pass.

## Results on 14 November 2026

Final Release validation passed 228 tests and all ten checks in `python3 scripts/validate.py --configuration release --artifacts .build/quota-switch-stability/validation-final`, including consumer compilation, six demo tests, iOS availability and DocC. Documentation coverage is 563/563 Swift declarations and 22/22 Python callables, measured lexically and with AST docstrings respectively. Independent review closed two comparability findings (local-session buckets and the inclusive output-size boundary); no material issue remains in the scoped switching change. The intermittent cleanup assertion above remains open despite an isolated pass and the final full pass.

The actual signed app used Automatic, Fastest, the demo's default five-second deadline, 256 output-token cap, paired refresh every request, 600-second optional cloud interval, and its existing disk profile. No model latency was injected. The warm continuation completed **29/29 correct foreground answers over 1,432.673 seconds (23.9 minutes)**, with **35/35 successful native calls: 29 local and six PCC**.

| Observation | Local seconds | PCC seconds | Result |
|---|---:|---:|---|
| Initial due probe, request 6 | 0.523 | 0.702 | Local; spacing 617.794 seconds |
| Longer output, requests 14–16 | 3.447–3.503 | 2.682–2.983 | Three qualified PCC selections after three local confirmations |
| First short response, request 17 | 0.382 | 0.616 | Cloud foreground; faster local shadow enabled the next unpaid local request |
| Final due probe, request 26 | 0.413 | 0.751 | Local; spacing 619.769 seconds |

Both probes were admitted and retained through three calibrated unpaid local follow-ups. During the first follow-ups, a real 1.642-second local spike made the weighted estimates favor PCC (1.177 seconds local versus 0.743 cloud). The new gate instead chose local confirmation at request 8, which completed in 0.639 seconds without a PCC call. This demonstrates the intended safeguard in the real app, without claiming an unobserved PCC timing for that request. The router also promoted PCC promptly after a genuine sustained workload change and returned to local after one paid short response.

All old cloud samples survived. The final profile contains 128 local and 17 cloud samples; thirteen oldest baseline local observations were trimmed by the existing per-provider bound. An opaque native network reassessment retained history. No material network change was attempted. Six deliberately corrupted evidence copies were rejected: missing native finish, altered duration, wrong answer, invented GUI time, lost cloud history, and missing matched duration.

The copied auditor initially recognized only the weighted `localFaster` UI label. A separately reviewed correction recognizes qualified unpaid `localCalibration` confirmations as well, preserving the frozen acceptance contract, all native/quota/history checks, the original auditor and both hashes. These confirmations are not described as weighted local victories.

The separate first cold request returned the correct PCC answer, but its local shadow did not complete within the remaining request budget. Native logs mark that local lane unsuccessful; Apple's response-complete event followed its cancellation, consistent with a cold-start deadline. The exact SDK error type was not exposed. Its timing was correctly excluded and the initial campaign refused further calls. The same app then continued warm with no additional warmup inference, unchanged settings and history, and a separate eleven-call cap. **Total for this task: seven PCC calls, including that cold request; thirty correct foreground answers.** This is a successful warm switching qualification, not a clean cold-start pass or proof of quota-optimal behavior under every future workload.

Evidence: `.build/live-gui-stable-switch-warm/verified-summary.json`, `additional-verification.json`, raw native logs, per-request checkpoints, GUI observations and retained profiles. The cold attempt is preserved separately under `.build/live-gui-stable-switch`. The app and owned log observers were closed after collection. The signed binary SHA-256 is `9bb2ff760a469e3c6c382808a6d51750a17ce52becca0eed55615d77c6d1d2de`; runtime image UUID `E3A9CDE2-17C6-3F7A-ACC6-5AEC03AA1DB3` matches that build. Source hashes remained unchanged after offline validation.

# ``AdaptiveModelRouting``

Route Apple Foundation Models through one product and one import, with explicit privacy policies and observable recovery.

## Overview

Keep one ``FoundationModelsRouter`` per stable workload. Use `.localOnly` when cloud is forbidden, `.cloudRequired` when a task needs cloud capabilities, and `.automatic` when either model's output is acceptable.

```swift
import AdaptiveModelRouting

// In an @MainActor app model on iOS/macOS 27+:
let router = FoundationModelsRouter(
    workload: "summaries",
    configuration: .init(customizing: .balanced, requestDeadline: .after(.seconds(30))),
    persistence: .memoryOnly
)
let summary = try await router.respond(to: transcript, policy: .localOnly)
```

Build with an iOS/macOS 27 SDK. Core APIs support iOS/macOS 26; the Apple adapter requires iOS/macOS 27. Provider qualification and a release tag remain separate from the offline validation in this repository.

## Topics

### Guides
- <doc:GettingStarted>
- <doc:PoliciesAndDeadlines>
- <doc:StreamingResponses>
- <doc:CalibrationAndStorage>
- <doc:ValidationAndSample>

### Apple model integration
- ``FoundationModelsRouter``
- ``FoundationModelsAdapterError``

### Routing and customization
- ``AdaptiveRouter``
- ``RoutingConfiguration``
- ``RoutingPolicy``
- ``RoutingWorkload``
- ``RoutingAvailability``
- ``InferenceExecutor``
- ``InferenceRoute``

### Streaming and request control
- ``RoutingStreamEvent``
- ``RoutingDeadline``
- ``RoutingRequestError``

### Explanations and calibration
- ``RoutingResult``
- ``RoutingResultStatus``
- ``RoutingDecision``
- ``RoutingReason``
- ``RoutingEstimate``
- ``RoutingAttempt``
- ``PerformanceProfile``
- ``RoutingPersistence``
- ``RoutingStorageStatus``

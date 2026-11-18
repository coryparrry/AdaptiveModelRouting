import Foundation
import Observation
import AdaptiveModelRouting

/// Selects fixture providers by default so launching the sample never consumes model quota.
public enum DemoMode: String, CaseIterable, Identifiable, Sendable {
    case simulated = "Simulated"
    case apple = "Apple models"
    public var id: String { rawValue }
}

/// Exposes the package's three hard routing policies in app-facing language.
public enum DemoPolicy: String, CaseIterable, Identifiable, Sendable {
    case local = "Local only"
    case automatic = "Automatic"
    case cloud = "Cloud required"
    public var id: String { rawValue }
    /// Maps app labels to the actual package constraint.
    var value: RoutingPolicy {
        switch self {
        case .local: .localOnly
        case .automatic: .automatic
        case .cloud: .cloudRequired
        }
    }
}

/// Lets the sample select presets without duplicating their tuning values.
public enum DemoPreset: String, CaseIterable, Identifiable, Sendable {
    case fastest = "Fastest"
    case balanced = "Balanced"
    case quality = "Quality first"
    case latency = "Latency first"
    public var id: String { rawValue }
    /// Uses the package's validated default configuration for each choice.
    var value: RoutingConfiguration {
        switch self {
        case .fastest: .fastest
        case .balanced: .balanced
        case .quality: .qualityFirst
        case .latency: .latencyFirst
        }
    }
}

/// Injects cloud behavior in simulated mode for deterministic recovery, partial-output and deadline demonstrations.
public enum DemoFault: String, CaseIterable, Identifiable, Sendable {
    case none = "None"
    case beforeOutput = "Fail before output"
    case afterOutput = "Fail after partial output"
    case stall = "Stall until deadline"
    public var id: String { rawValue }
}

/// Identifies an attempt row for its lifetime rather than regenerating identity during rendering.
public struct DemoAttempt: Identifiable, Sendable {
    public let id = UUID()
    public let route: String
    public let outcome: String
    public let duration: String
}

/// Keeps disk opt-in independent for simulated and Apple workloads.
private struct DemoStoragePreferences: Codable {
    var simulated = false
    var apple = false

    /// Reads and updates the explicit choice for exactly one provider mode.
    subscript(mode: DemoMode) -> Bool {
        get { mode == .simulated ? simulated : apple }
        set {
            switch mode {
            case .simulated: simulated = newValue
            case .apple: apple = newValue
            }
        }
    }
}

/// Retains exactly one router owner for the current mode and configuration.
@MainActor
private enum DemoRoutingOwner {
    case simulated(AdaptiveRouter)
    case apple(FoundationModelsRouter)

    /// Provides the same storage and calibration controls for either provider.
    var router: AdaptiveRouter {
        switch self {
        case .simulated(let router): router
        case .apple(let adapter): adapter.router
        }
    }
}

/// Owns the sample's routing flow and guards observable state against late cancelled-task completion.
@MainActor
@Observable
public final class DemoModel {
    public var prompt = "Summarize the trade-offs between local and cloud models."
    public var mode: DemoMode = .simulated {
        didSet { if mode != oldValue { replaceOwner() } }
    }
    public var policy: DemoPolicy = .local
    public var preset: DemoPreset = .fastest {
        didSet { if preset != oldValue { replaceOwner() } }
    }
    public var fault: DemoFault = .none
    public var deadlineSeconds = 5.0 {
        didSet { if deadlineSeconds != oldValue { replaceOwner() } }
    }
    public var persistCalibration: Bool { storagePreferences[mode] }
    public private(set) var output = ""
    public private(set) var status = "Ready"
    public private(set) var isRunning = false
    public private(set) var errorMessage: String?
    public private(set) var selectionReason = "No request yet"
    public private(set) var attempts: [DemoAttempt] = []
    public private(set) var sampleCount = 0
    public private(set) var storageLabel = "In memory"
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var visibleWindows = Set<UUID>()
    @ObservationIgnored private let cacheRoot: URL
    private var storagePreferences = DemoStoragePreferences()
    @ObservationIgnored private lazy var owner = makeOwner()
    var activeRouter: AdaptiveRouter { owner.router }

    /// Starts with fixture routing and restores only the user's explicit calibration-storage preference.
    public init(cacheRoot: URL = URL.applicationSupportDirectory.appendingPathComponent("AdaptiveModelRoutingDemo")) {
        self.cacheRoot = cacheRoot
        // A legacy global Boolean cannot establish permission for either individual mode.
        if let data = try? Data(contentsOf: cacheRoot.appendingPathComponent("storage-preference.json")),
           let preferences = try? JSONDecoder().decode(DemoStoragePreferences.self, from: data) {
            storagePreferences = preferences
        }
        refreshProfile()
    }

    /// Runs one streaming request; a generation token prevents an old task from overwriting a later run.
    public func start() {
        guard !isRunning, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        generation += 1
        let token = generation
        let prompt = prompt
        let requestOwner = owner
        let policy = policy.value
        let fault = fault
        output = ""
        attempts = []
        errorMessage = nil
        status = "Generating…"
        isRunning = true
        let observer: (RoutingAttempt) -> Void = { [weak self] attempt in
            guard let self, self.generation == token else { return }
            self.attempts.append(.init(route: Self.routeName(attempt.route), outcome: attempt.outcome.rawValue,
                duration: String(format: "%.3f s", attempt.seconds)))
        }
        task = Task { @MainActor [weak self] in
            guard let self, self.generation == token, !Task.isCancelled else { return }
            defer {
                if self.generation == token { self.isRunning = false; self.task = nil; self.refreshProfile() }
            }
            do {
                let stream: AsyncThrowingStream<RoutingStreamEvent<String>, any Error>
                switch requestOwner {
                case .apple(let apple):
                    stream = apple.stream(to: prompt, policy: policy, onAttempt: observer)
                case .simulated(let core):
                    stream = core.stream(inputTokens: max(1, (prompt.utf8.count + 3) / 4), localContextCapacity: 8_192,
                        policy: policy, workload: .init(expectedOutputTokens: 256), onAttempt: observer,
                        cloud: { self.fixtureStream(route: .cloud, fault: fault) },
                        onDevice: { self.fixtureStream(route: .onDevice, fault: .none) })
                }
                for try await event in stream {
                    guard self.generation == token else { break }
                    switch event {
                    case .selected(let decision): self.selectionReason = Self.reasonName(decision.reason)
                    case .update(let text, _): self.output = text
                    case .completed(let result):
                        self.output = result.value ?? self.output
                        self.selectionReason = Self.reasonName(result.decision.reason)
                        switch result.status {
                        case .completed: self.status = result.route == .onDevice ? "Completed on device" : "Completed in cloud"
                        case .requiresChunking: self.status = "Split the input into smaller parts"
                        case .unavailable: self.status = "No permitted model is available"
                        }
                    }
                }
                try Task.checkCancellation()
            } catch is CancellationError {
                if self.generation == token { self.status = "Cancelled" }
            } catch {
                if self.generation == token {
                    self.status = self.output.isEmpty ? "Request failed" : "Stopped after partial output"
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Registers one visible view sharing this demo session.
    public func windowAppeared(_ id: UUID) { visibleWindows.insert(id) }

    /// Stops foreground and calibration work once the last view leaves the shared session.
    public func windowDisappeared(_ id: UUID) {
        guard visibleWindows.remove(id) != nil, visibleWindows.isEmpty else { return }
        cancel()
    }

    /// Cancels ongoing foreground or calibration work while preserving displayed output.
    public func cancel() {
        activeRouter.cancelCalibration()
        guard isRunning else { return }
        generation += 1
        task?.cancel()
        task = nil
        isRunning = false
        status = "Cancelled"
        refreshProfile()
    }

    /// Supports deterministic model-level smoke tests without opening a window or invoking Apple models.
    public func waitUntilFinished() async { await task?.value }

    /// Resets only the selected demo mode's calibration and reports filesystem failures.
    public func resetProfile() {
        guard !isRunning else { return }
        do { try activeRouter.resetProfile(); status = "Calibration reset"; errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
        refreshProfile()
    }

    /// Applies an explicit storage choice to the selected workload and clears its file when disabling disk.
    public func setPersistence(_ enabled: Bool) {
        guard !isRunning else { return }
        do {
            var updated = storagePreferences
            updated[mode] = enabled
            try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(updated)
            try data.write(to: cacheRoot.appendingPathComponent("storage-preference.json"), options: .atomic)
            storagePreferences = updated
            try activeRouter.setPersistence(enabled ? .disk : .memoryOnly)
            errorMessage = nil
        } catch {
            // Honor an opt-out for this session even if preference persistence or file removal failed.
            if !enabled {
                storagePreferences[mode] = false
                try? activeRouter.setPersistence(.memoryOnly, clearExistingCache: false)
            }
            errorMessage = error.localizedDescription
        }
        refreshProfile()
    }

    /// Retires the previous owner before another router can read or write the same cache.
    private func replaceOwner() {
        cancel()
        // The memory-only transition with clearing disabled does no file I/O. A late SDK
        // error can still carry a retry hint, but the retired owner can no longer write the file.
        try? activeRouter.setPersistence(.memoryOnly, clearExistingCache: false)
        owner = makeOwner()
        refreshProfile()
    }

    /// Opens the selected workload with its own persisted storage choice.
    private func makeOwner() -> DemoRoutingOwner {
        let configuration = RoutingConfiguration(customizing: preset.value,
            requestDeadline: .after(.seconds(max(0.001, deadlineSeconds))))
        let persistence: RoutingPersistence = persistCalibration ? .disk : .memoryOnly
        switch mode {
        case .apple:
            return .apple(FoundationModelsRouter(workload: "demo", instructions: "Answer clearly and concisely.",
                configuration: configuration, options: .init(maximumResponseTokens: 256),
                cacheRoot: cacheRoot.appendingPathComponent("apple"), persistence: persistence))
        case .simulated:
            return .simulated(AdaptiveRouter(directory: cacheRoot.appendingPathComponent("simulated"), monitorConnection: false,
                configuration: configuration, persistence: persistence, calibrationIdentifier: "simulated-v1"))
        }
    }

    /// Updates presentation fields after controls or requests change calibration.
    private func refreshProfile() {
        sampleCount = activeRouter.profile.samples.count
        switch activeRouter.storageStatus {
        case .memoryOnly: storageLabel = "In memory"
        case .notPersisted: storageLabel = "Not saved yet"
        case .persisted: storageLabel = "Saved"
        case .unavailable: storageLabel = "Storage unavailable"
        case .preservedCache: storageLabel = "Existing cache preserved"
        }
    }

    /// Simulates cumulative model snapshots; fixture failures apply only to the cloud lane.
    private func fixtureStream(route: InferenceRoute, fault: DemoFault) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let producer = Task { @MainActor in
                do {
                    if fault == .beforeOutput { throw URLError(.timedOut) }
                    if fault == .stall { try await Task.sleep(for: .seconds(120)) }
                    let words = "Simulated \(route == .onDevice ? "local" : "cloud") reply: cumulative snapshots let your app show progress while the router measures performance.".split(separator: " ")
                    var text = ""
                    for (index, word) in words.enumerated() {
                        try await Task.sleep(for: .milliseconds(route == .onDevice ? 12 : 40))
                        text += (text.isEmpty ? "" : " ") + word
                        if case .terminated = continuation.yield(text) { throw CancellationError() }
                        if fault == .afterOutput && index == 2 { throw URLError(.timedOut) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    /// Formats provider identity for the sample UI.
    private static func routeName(_ route: InferenceRoute) -> String { route == .onDevice ? "On device" : "Cloud" }

    /// Turns selection metadata into a concise explanation without exposing implementation state in the basic flow.
    private static func reasonName(_ reason: RoutingReason) -> String {
        switch reason {
        case .cloudRequired: "Cloud required by policy"
        case .localOnly: "Local-only policy"
        case .cloudPreferred: "Cloud preferred for this workload"
        case .localCalibration: "Measuring local speed"
        case .localFaster: "Local is meaningfully faster"
        case .offline: "Offline: using the device"
        case .cloudBackoff: "Recent cloud failure"
        case .localBackoff: "Recent local failure"
        case .insufficientEvidence: "Collecting timings"
        case .cloudRefresh: "Checking cloud speed again"
        case .localUnavailable: "Local model not ready"
        case .cloudUnavailable: "Cloud model not ready"
        case .cloudQuotaConserved: "Preserving cloud quota"
        case .localContextExceeded: "Input exceeds local context"
        case .noAvailableProvider: "No model is ready"
        }
    }
}

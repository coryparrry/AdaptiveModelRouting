import SwiftUI
import RoutingDemoSupport

/// Runs a native sample whose default mode uses only deterministic simulated providers.
@main
@MainActor
struct RoutingDemoApp: App {
    @State private var model = DemoModel()

    var body: some Scene {
        WindowGroup("Adaptive Model Routing") { RoutingDemoView(model: model) }
            .defaultSize(width: 860, height: 780)
    }
}

/// Keeps the basic prompt/run/response flow visible and places developer controls behind Advanced.
@MainActor
struct RoutingDemoView: View {
    @Bindable var model: DemoModel
    @State private var advanced = false
    @State private var windowID = UUID()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Adaptive Model Routing").font(.largeTitle.bold())
                    Text("One import. Local and cloud models. Clear routing decisions.").foregroundStyle(.secondary)
                }
                request
                response
                DisclosureGroup("Advanced", isExpanded: $advanced) { advancedControls.padding(.top, 12) }
            }
            .padding(24)
            .frame(maxWidth: 1_000, alignment: .leading)
        }
        .frame(minWidth: 600, minHeight: 640)
        .onAppear { model.windowAppeared(windowID) }
        .onDisappear { model.windowDisappeared(windowID) }
    }

    private var request: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Picker("Providers", selection: $model.mode) {
                        ForEach(DemoMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("provider-mode")
                    Picker("Policy", selection: $model.policy) {
                        ForEach(DemoPolicy.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .frame(width: 240)
                    .accessibilityIdentifier("routing-policy")
                }
                .disabled(model.isRunning)
                Text(model.mode == .simulated
                    ? "Simulated providers: no model requests are made."
                    : "Apple model availability depends on your device and app signing. Cloud use requires approved PCC access.")
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $model.prompt)
                    .frame(height: 105)
                    .padding(6)
                    .border(Color.secondary.opacity(0.25))
                    .accessibilityLabel("Prompt")
                    .accessibilityIdentifier("prompt")
                    .disabled(model.isRunning)
                HStack(spacing: 12) {
                    Button("Run") { model.start() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.isRunning || model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("run")
                    Button("Cancel") { model.cancel() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(!model.isRunning)
                        .accessibilityIdentifier("cancel")
                    if model.isRunning { ProgressView().controlSize(.small).accessibilityLabel("Generating") }
                    Spacer()
                    Text(model.status).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("request-status")
                }
            }
            .padding(8)
        } label: { Text("Request").font(.headline) }
    }

    private var response: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).accessibilityIdentifier("request-error")
                }
                Text(model.output.isEmpty ? "Run a request to see its response." : model.output)
                    .foregroundStyle(model.output.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                    .accessibilityIdentifier("response")
            }
            .padding(8)
        } label: { Text("Response").font(.headline) }
    }

    private var advancedControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("Preset", selection: $model.preset) {
                    ForEach(DemoPreset.allCases) { Text($0.rawValue).tag($0) }
                }
                Stepper("Deadline: \(Int(model.deadlineSeconds)) s", value: $model.deadlineSeconds, in: 1...120, step: 1)
                    .frame(width: 210)
                    .accessibilityIdentifier("request-deadline")
            }
            .disabled(model.isRunning)
            if model.mode == .simulated {
                Picker("Simulated cloud fault", selection: $model.fault) {
                    ForEach(DemoFault.allCases) { Text($0.rawValue).tag($0) }
                }
                .disabled(model.isRunning || model.policy == .local)
                .accessibilityIdentifier("simulated-fault")
                Text("Choose Automatic to try fallback. Reset calibration to clear previous failure backoff.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            LabeledContent("Selection", value: model.selectionReason)
            LabeledContent("Stored timings", value: "\(model.sampleCount)")
            LabeledContent("Storage", value: model.storageLabel)
            Toggle("Save calibration for this demo mode", isOn: Binding(
                get: { model.persistCalibration }, set: { model.setPersistence($0) }))
                .disabled(model.isRunning)
            Button("Reset selected profile") { model.resetProfile() }
                .disabled(model.isRunning).accessibilityIdentifier("reset-profile")
            if !model.attempts.isEmpty {
                Divider()
                ForEach(model.attempts) { attempt in
                    HStack {
                        Text(attempt.route).frame(width: 95, alignment: .leading)
                        Text(attempt.outcome).foregroundStyle(.secondary)
                        Spacer()
                        Text(attempt.duration).monospacedDigit()
                    }
                }
            }
        }
    }
}

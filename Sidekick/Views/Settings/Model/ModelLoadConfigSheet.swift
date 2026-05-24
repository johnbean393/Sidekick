//
//  ModelLoadConfigSheet.swift
//  Sidekick
//
//  Per-model load-configuration sheet shown after a `.gguf` is picked
//  (Add Model / Setup) or from the gear button on an existing row.
//  Lets the user choose a context length within the safe memory budget
//  computed by ``GGUFEstimator`` and, behind an "Advanced" disclosure,
//  override the architecture-recommended sampling defaults.
//

import OSLog
import SwiftUI

struct ModelLoadConfigSheet: View {

    private static let logger: Logger = .init(
        subsystem: Bundle.main.bundleIdentifier ?? "Sidekick",
        category: String(describing: ModelLoadConfigSheet.self)
    )

    /// Whether the sheet is being shown for a freshly added model
    /// (changes the primary button label and prevents Cancel from
    /// orphaning the model in the list).
    enum Mode {
        case add
        case edit

        var primaryButtonLabel: String {
            switch self {
                case .add:  return String(localized: "Add Model")
                case .edit: return String(localized: "Save")
            }
        }
    }

    let modelUrl: URL
    let mode: Mode
    @Binding var isPresented: Bool
    /// Invoked after a successful save with the chosen context length.
    /// Lets the caller (setup flow, list view) advance its own state.
    var onSaved: ((Int) -> Void)? = nil
    /// Invoked when the user cancels an Add. Used by the list view to
    /// undo the speculative `ModelManager.add(_:)` call so cancelled
    /// adds don't leave a half-configured row.
    var onCancelledAdd: (() -> Void)? = nil

    // MARK: - Estimator state

    private enum EstimatorState {
        case loading
        case ready(GGUFEstimator.Estimate)
        case fallback(trainedMax: Int)
        case failed(String)
    }

    @State private var estimator: EstimatorState = .loading

    // MARK: - Editable state

    @State private var contextLength: Double = 4_096
    @State private var temperature: Double? = nil
    @State private var topP: Double? = nil
    @State private var topK: Int? = nil
    @State private var minP: Double? = nil
    @State private var repetitionPenalty: Double? = nil
    @State private var presencePenalty: Double? = nil
    @State private var frequencyPenalty: Double? = nil

    @State private var showAdvanced: Bool = false
    @State private var hasInitialized: Bool = false

    // MARK: - Derived

    private var architecture: ModelArchitecture? {
        ModelArchitecture.detect(modelUrl: modelUrl)
    }

    private var architectureDefaults: SamplingParameters {
        return architecture?.recommendedSampling(useReasoning: true)
            ?? SamplingParameters(temperature: 0.7)
    }

    private var modelDisplayName: String {
        modelUrl.deletingPathExtension().lastPathComponent
    }

    private var safeMaxContextLength: Int {
        switch estimator {
            case .loading:
                return 8_192
            case .ready(let estimate):
                return max(2_048, estimate.safeMaxContextLength)
            case .fallback(let trainedMax):
                return max(2_048, trainedMax)
            case .failed:
                return 32_768
        }
    }

    private var trainedContextLength: Int? {
        switch estimator {
            case .ready(let estimate):
                return estimate.trainedContextLength
            case .fallback(let trainedMax):
                return trainedMax
            case .loading, .failed:
                return nil
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    contextLengthSection
                    Divider()
                    advancedSection
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }
            Divider()
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 460, idealHeight: 520)
        .task(id: modelUrl) {
            if !hasInitialized {
                hasInitialized = true
                loadExistingConfig()
            }
            await runEstimator()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(modelDisplayName)
                    .font(.title2)
                    .bold()
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let architecture {
                    Text(architecture.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            memoryBadge
        }
    }

    private var memoryBadge: some View {
        VStack(alignment: .trailing, spacing: 4) {
            switch estimator {
                case .loading:
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Estimating…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .ready(let estimate):
                    Text("Estimated memory")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(formatBytes(estimate.estimatedBytesAt(ctxSize: Int(contextLength)))) / \(formatGB(estimate.availableMemoryBytes)) free")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.primary)
                case .fallback:
                    Text("Memory estimate unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
            }
        }
    }

    // MARK: - Context length

    private var contextLengthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Context Length")
                    .font(.headline)
                Spacer()
                EditableNumericLabel(
                    value: Binding<Double>(
                        get: { contextLength },
                        set: { contextLength = clampContextLength($0) }
                    ),
                    range: 2_048...Double(safeMaxContextLength),
                    formatter: { formatNumber(Int($0)) },
                    parser: { Double($0.replacingOccurrences(of: ",", with: "")) },
                    width: 96,
                    isModified: true
                )
            }
            Slider(
                value: Binding<Double>(
                    get: { contextLength },
                    set: { contextLength = clampContextLength($0) }
                ),
                in: 2_048...Double(safeMaxContextLength)
            )
            .disabled({
                if case .loading = estimator { return true }
                return false
            }())
            HStack {
                Text("2,048")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if let trained = trainedContextLength {
                    Text("Safe max: \(formatNumber(safeMaxContextLength)) (trained: \(formatNumber(trained)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Safe max: \(formatNumber(safeMaxContextLength))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Maximum information the model can consider per query. The slider stops at the largest context that comfortably fits in your Mac's memory.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Snap a context length to a 512-token multiple and clamp it into
    /// the currently allowed range.
    private func clampContextLength(_ raw: Double) -> Double {
        let lower = 2_048.0
        let upper = max(lower, Double(safeMaxContextLength))
        let clamped = min(max(raw, lower), upper)
        let snapped = (clamped / 512.0).rounded() * 512.0
        return min(max(snapped, lower), upper)
    }

    // MARK: - Advanced parameters

    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 14) {
                samplerRow(
                    title: "Temperature",
                    value: $temperature,
                    fallback: architectureDefaults.temperature,
                    range: 0.0...2.0,
                    step: 0.05,
                    format: "%.2f"
                )
                samplerRow(
                    title: "Top P",
                    value: $topP,
                    fallback: architectureDefaults.topP,
                    range: 0.0...1.0,
                    step: 0.01,
                    format: "%.2f"
                )
                samplerIntRow(
                    title: "Top K",
                    value: $topK,
                    fallback: architectureDefaults.topK,
                    range: 0...200
                )
                samplerRow(
                    title: "Min P",
                    value: $minP,
                    fallback: architectureDefaults.minP,
                    range: 0.0...1.0,
                    step: 0.01,
                    format: "%.2f"
                )
                samplerRow(
                    title: "Repetition Penalty",
                    value: $repetitionPenalty,
                    fallback: architectureDefaults.repetitionPenalty,
                    range: 0.5...2.0,
                    step: 0.05,
                    format: "%.2f"
                )
                samplerRow(
                    title: "Presence Penalty",
                    value: $presencePenalty,
                    fallback: architectureDefaults.presencePenalty,
                    range: -2.0...2.0,
                    step: 0.05,
                    format: "%.2f"
                )
                samplerRow(
                    title: "Frequency Penalty",
                    value: $frequencyPenalty,
                    fallback: architectureDefaults.frequencyPenalty,
                    range: -2.0...2.0,
                    step: 0.05,
                    format: "%.2f"
                )
                HStack {
                    Spacer()
                    Button("Reset to defaults") {
                        resetSamplingToDefaults()
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.top, 8)
        } label: {
            Text("Advanced Parameters")
                .font(.headline)
        }
    }

    /// A row showing one floating-point sampler. When `value` is `nil`,
    /// the architecture default is shown as a placeholder and saved as
    /// "use architecture default" (i.e. `nil`).
    private func samplerRow(
        title: String,
        value: Binding<Double?>,
        fallback: Double?,
        range: ClosedRange<Double>,
        step: Double,
        format: String
    ) -> some View {
        let resolved = value.wrappedValue ?? fallback ?? range.lowerBound
        let snapBinding = Binding<Double>(
            get: { resolved },
            set: { newValue in
                value.wrappedValue = snap(newValue, step: step, in: range)
            }
        )
        return HStack(spacing: 12) {
            Text(title)
                .frame(width: 160, alignment: .leading)
            Slider(value: snapBinding, in: range)
            EditableNumericLabel(
                value: snapBinding,
                range: range,
                formatter: { String(format: format, $0) },
                parser: { Double($0) },
                width: 60,
                isModified: value.wrappedValue != nil
            )
        }
    }

    /// Same as ``samplerRow`` but for integer-valued samplers (top-k).
    private func samplerIntRow(
        title: String,
        value: Binding<Int?>,
        fallback: Int?,
        range: ClosedRange<Int>
    ) -> some View {
        let resolved = value.wrappedValue ?? fallback ?? range.lowerBound
        let doubleRange = Double(range.lowerBound)...Double(range.upperBound)
        let snapBinding = Binding<Double>(
            get: { Double(resolved) },
            set: { newValue in
                value.wrappedValue = Int(snap(newValue, step: 1, in: doubleRange).rounded())
            }
        )
        return HStack(spacing: 12) {
            Text(title)
                .frame(width: 160, alignment: .leading)
            Slider(value: snapBinding, in: doubleRange)
            EditableNumericLabel(
                value: snapBinding,
                range: doubleRange,
                formatter: { "\(Int($0.rounded()))" },
                parser: { Double($0) },
                width: 60,
                isModified: value.wrappedValue != nil
            )
        }
    }

    /// Snap a continuous value to the nearest multiple of `step` and
    /// clamp it into `range`.
    private func snap(
        _ value: Double,
        step: Double,
        in range: ClosedRange<Double>
    ) -> Double {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        guard step > 0 else { return clamped }
        let snapped = (clamped / step).rounded() * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") {
                cancel()
            }
            .keyboardShortcut(.cancelAction)
            Button(mode.primaryButtonLabel) {
                save()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled({
                if case .loading = estimator { return true }
                return false
            }())
        }
    }

    // MARK: - Actions

    private func loadExistingConfig() {
        guard let entity = ModelManager.entity(for: modelUrl) else { return }
        if let ctx = entity.contextLength {
            contextLength = Double(ctx)
        }
        temperature = entity.temperature
        topP = entity.topP
        topK = entity.topK
        minP = entity.minP
        repetitionPenalty = entity.repetitionPenalty
        presencePenalty = entity.presencePenalty
        frequencyPenalty = entity.frequencyPenalty
        // Promote a cached estimate to the "ready" state so the slider
        // can settle before the live estimator returns. The fresh run
        // will overwrite this if memory has changed.
        if let safe = entity.safeMaxContextLength,
           let trained = entity.trainedContextLength,
           let computedFor = entity.safeMaxComputedForMemoryGB,
           computedFor == Int(GGUFEstimator.unifiedMemoryBytes() / (1024 * 1024 * 1024)) {
            estimator = .ready(.init(
                trainedContextLength: trained,
                safeMaxContextLength: safe,
                estimatedBytesAtSafeMax: 0,
                estimatedBytesAtBaseline: 0,
                availableMemoryBytes: GGUFEstimator.unifiedMemoryBytes(),
                availableMemoryGB: computedFor
            ))
        }
    }

    private func runEstimator() async {
        let availableBytes = GGUFEstimator.availableMemoryBytes()
        let unifiedBytes = GGUFEstimator.unifiedMemoryBytes()
        // Bias the budget toward total unified memory rather than the
        // "free right now" value, otherwise an open Chrome with 20 tabs
        // would shrink the safe ceiling for the rest of the session.
        let budget = max(availableBytes, UInt64(Double(unifiedBytes) * 0.6))
        do {
            let estimate = try await GGUFEstimator.estimate(
                model: modelUrl,
                availableMemoryBytes: budget,
                headroomFraction: 0.20
            )
            await MainActor.run {
                estimator = .ready(estimate)
                // Initialise to safe max only if the user hasn't already
                // overridden it via a saved per-model value.
                let saved = ModelManager.entity(for: modelUrl)?.contextLength
                if saved == nil {
                    contextLength = Double(estimate.safeMaxContextLength)
                } else {
                    contextLength = min(
                        Double(saved ?? estimate.safeMaxContextLength),
                        Double(estimate.safeMaxContextLength)
                    )
                }
            }
        } catch {
            Self.logger.warning(
                "GGUFEstimator failed for \(modelDisplayName, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            await MainActor.run {
                if let trainedCtx = GGUFMetadataReader.readArchitectureInfo(from: modelUrl)?.contextLength {
                    estimator = .fallback(trainedMax: trainedCtx)
                    if ModelManager.entity(for: modelUrl)?.contextLength == nil {
                        contextLength = Double(min(trainedCtx, 32_768))
                    }
                } else {
                    estimator = .failed(String(localized: "Memory estimate unavailable; using defaults."))
                }
            }
        }
    }

    private func resetSamplingToDefaults() {
        temperature = nil
        topP = nil
        topK = nil
        minP = nil
        repetitionPenalty = nil
        presencePenalty = nil
        frequencyPenalty = nil
    }

    private func save() {
        let chosenCtx = Int(contextLength)
        let snapshotSafeMax: Int?
        let snapshotTrained: Int?
        let snapshotMemoryGB: Int?
        switch estimator {
            case .ready(let estimate):
                snapshotSafeMax = estimate.safeMaxContextLength
                snapshotTrained = estimate.trainedContextLength
                snapshotMemoryGB = estimate.availableMemoryGB
            case .fallback(let trainedMax):
                snapshotSafeMax = nil
                snapshotTrained = trainedMax
                snapshotMemoryGB = nil
            case .loading, .failed:
                snapshotSafeMax = nil
                snapshotTrained = nil
                snapshotMemoryGB = nil
        }
        ModelManager.updateConfig(for: modelUrl) { entity in
            entity.contextLength = chosenCtx
            entity.temperature = temperature
            entity.topP = topP
            entity.topK = topK
            entity.minP = minP
            entity.repetitionPenalty = repetitionPenalty
            entity.presencePenalty = presencePenalty
            entity.frequencyPenalty = frequencyPenalty
            if let snapshotTrained {
                entity.trainedContextLength = snapshotTrained
            }
            if let snapshotSafeMax {
                entity.safeMaxContextLength = snapshotSafeMax
                entity.safeMaxComputedAt = Date.now
                entity.safeMaxComputedForMemoryGB = snapshotMemoryGB
            }
        }
        NotificationCenter.default.post(
            name: Notifications.changedInferenceConfig.name,
            object: nil
        )
        onSaved?(chosenCtx)
        isPresented = false
    }

    private func cancel() {
        if mode == .add {
            onCancelledAdd?()
        }
        isPresented = false
    }

    // MARK: - Formatting

    private func formatNumber(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func formatGB(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1024.0 / 1024.0 / 1024.0
        return String(format: "%.1f GB", gb)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1024.0 / 1024.0 / 1024.0
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / 1024.0 / 1024.0
        return String(format: "%.0f MB", mb)
    }
}

// MARK: - Editable numeric label

/// A click-to-edit numeric value display. Renders as a `Text` by
/// default and switches to a `TextField` when tapped, committing the
/// parsed value on `Return` or focus loss. Used by both the context
/// length section and the sampler rows so the user can either drag
/// the slider or type the exact value they want.
private struct EditableNumericLabel: View {

    @Binding var value: Double
    let range: ClosedRange<Double>
    let formatter: (Double) -> String
    let parser: (String) -> Double?
    let width: CGFloat
    let isModified: Bool

    @State private var isEditing: Bool = false
    @State private var draft: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isEditing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .font(.body.monospacedDigit())
                    .focused($isFocused)
                    .frame(width: width, alignment: .trailing)
                    .onSubmit { commit() }
                    .onChange(of: isFocused) { _, focused in
                        if !focused { commit() }
                    }
                    .onExitCommand { cancelEdit() }
            } else {
                Text(formatter(value))
                    .font(.body.monospacedDigit())
                    .frame(width: width, alignment: .trailing)
                    .foregroundStyle(isModified ? .primary : .secondary)
                    .contentShape(Rectangle())
                    .onTapGesture { beginEdit() }
            }
        }
    }

    private func beginEdit() {
        draft = formatter(value)
        isEditing = true
        DispatchQueue.main.async {
            isFocused = true
        }
    }

    private func commit() {
        defer {
            isEditing = false
            isFocused = false
        }
        guard let parsed = parser(draft.trimmingCharacters(in: .whitespaces)) else {
            return
        }
        let clamped = min(max(parsed, range.lowerBound), range.upperBound)
        value = clamped
    }

    private func cancelEdit() {
        isEditing = false
        isFocused = false
    }
}

// MARK: - Estimate convenience

private extension GGUFEstimator.Estimate {

    /// Linear-interpolated memory estimate at an arbitrary context size,
    /// derived from the baseline + safe-max probes captured at run time.
    func estimatedBytesAt(ctxSize: Int) -> UInt64 {
        let lowCtx = 4_096
        let highCtx = max(lowCtx + 1, safeMaxContextLength)
        let dx = highCtx - lowCtx
        if dx <= 0 { return estimatedBytesAtBaseline }
        let slope = Double(Int64(estimatedBytesAtSafeMax) - Int64(estimatedBytesAtBaseline))
            / Double(dx)
        let base = Double(estimatedBytesAtBaseline) - slope * Double(lowCtx)
        let value = base + slope * Double(ctxSize)
        return value < 0 ? 0 : UInt64(value)
    }
}

import SwiftUI
import MLXTaskExtractor

struct ContentView: View {
    @StateObject private var model = BenchmarkViewModel()
    @State private var isAddingCustomModel = false
    @State private var customModelID = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                inputPane
                    .frame(minWidth: 360)
                resultsPane
                    .frame(minWidth: 500)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("TaskBench").font(.title2.bold())
                Text("Native MLX screenshot → OCR → task extraction benchmark")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isWorking { ProgressView().controlSize(.small) }
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(16)
    }

    private var inputPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("1. Input") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button("Capture screen", systemImage: "camera.viewfinder") {
                                Task { await model.capture() }
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Choose image…", systemImage: "photo") {
                                Task { await model.chooseImage() }
                            }
                        }
                        if let image = model.screenshot {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 210)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            ContentUnavailableView(
                                "No screenshot",
                                systemImage: "rectangle.dashed",
                                description: Text("Screen Recording permission is requested on first capture.")
                            )
                            .frame(height: 160)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("2. OCR text") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $model.recognizedText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 150)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                        if let duration = model.ocrDuration {
                            Text("Vision OCR: \(duration.formatted(.number.precision(.fractionLength(2))))s · editable before benchmarking")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                GroupBox("3. Models") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Selected models")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(model.models.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        if model.models.isEmpty {
                            Text("No models selected")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                        } else {
                            ModelTagLayout(spacing: 7) {
                                ForEach(model.models, id: \.self) { id in
                                    ModelTag(
                                        id: id,
                                        option: model.modelOption(for: id),
                                        isDisabled: model.isWorking
                                    ) {
                                        model.removeModel(id)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        HStack {
                            Menu {
                                if model.availableCatalogModels.isEmpty {
                                    Text("All catalog models are selected")
                                } else {
                                    ForEach(model.availableCatalogModels) { option in
                                        Button {
                                            model.addModel(option.id)
                                        } label: {
                                            Text("\(option.name) — \(option.specification)")
                                        }
                                    }
                                }
                                Divider()
                                Button("Custom Hugging Face ID…", systemImage: "text.badge.plus") {
                                    customModelID = ""
                                    isAddingCustomModel = true
                                }
                            } label: {
                                Label("Add model", systemImage: "plus")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .disabled(model.isWorking)
                            .popover(isPresented: $isAddingCustomModel, arrowEdge: .bottom) {
                                customModelPopover
                            }

                            Button("Recommended for this Mac", systemImage: "cpu") {
                                model.useRecommendedModels()
                            }
                            .disabled(model.isWorking)
                            Spacer()
                        }

                        Divider()

                        HStack {
                            Stepper("Runs: \(model.runs)", value: $model.runs, in: 1...7)
                            Spacer()
                            Toggle("Warm up", isOn: $model.warmUp)
                                .toggleStyle(.checkbox)
                        }

                        Text("Models run in tag order; downloaded weights remain cached locally.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Button {
                    Task { await model.runBenchmarks() }
                } label: {
                    Label("Run benchmark", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isWorking || model.recognizedText.isEmpty || model.models.isEmpty)
            }
            .padding(16)
        }
    }

    private var customModelPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Add custom model")
                    .font(.headline)
                Text("Enter a Hugging Face MLX model ID")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField("organization/model-name", text: $customModelID)
                .textFieldStyle(.roundedBorder)
                .frame(width: 310)
                .onSubmit(addCustomModel)
            HStack {
                Spacer()
                Button("Cancel") {
                    isAddingCustomModel = false
                }
                Button("Add") {
                    addCustomModel()
                }
                .buttonStyle(.borderedProminent)
                .disabled(customModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
    }

    private func addCustomModel() {
        guard model.addModel(customModelID) else { return }
        customModelID = ""
        isAddingCustomModel = false
    }

    private var resultsPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Results").font(.headline)
                Spacer()
                Text("Sorted by median wall time")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Export JSON…", systemImage: "square.and.arrow.up") {
                    model.exportResults()
                }
                .disabled(model.results.isEmpty || model.isWorking)
            }

            if model.results.isEmpty {
                ContentUnavailableView(
                    "No benchmark results",
                    systemImage: "chart.bar.xaxis",
                    description: Text("Results include end-to-end latency, model load time, throughput, and extracted tasks.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { rank, result in
                            ResultCard(
                                rank: rank + 1,
                                result: result,
                                isWorking: model.isWorking,
                                isWarming: model.warmingModel == result.model,
                                isRunningOnce: model.runningOnceModel == result.model,
                                isLoaded: model.loadedModelID == result.model,
                                warm: {
                                    Task { await model.warmModel(modelID: result.model) }
                                },
                                runOnce: {
                                    Task { await model.runOnce(modelID: result.model) }
                                }
                            )
                        }
                    }
                }
            }
        }
        .padding(16)
    }
}

private struct ModelTag: View {
    let id: String
    let option: BenchmarkViewModel.ModelOption?
    let isDisabled: Bool
    let remove: () -> Void

    private var shortID: String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    var body: some View {
        HStack(spacing: 7) {
            VStack(alignment: .leading, spacing: 0) {
                Text(option?.name ?? shortID)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if let specification = option?.specification {
                    Text(specification)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Button {
                remove()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 16, height: 16)
                    .background(.secondary.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .help("Remove \(option?.name ?? shortID)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 7)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.10), in: Capsule())
        .overlay {
            Capsule().stroke(Color.accentColor.opacity(0.24))
        }
        .help(id)
        .fixedSize()
    }
}

private struct ModelTagLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maximumWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maximumWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(
            width: proposal.width ?? usedWidth,
            height: subviews.isEmpty ? 0 : y + rowHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct ResultCard: View {
    let rank: Int
    let result: BenchmarkResult
    let isWorking: Bool
    let isWarming: Bool
    let isRunningOnce: Bool
    let isLoaded: Bool
    let warm: () -> Void
    let runOnce: () -> Void
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("Re-warm", systemImage: "flame") {
                        warm()
                    }
                    .disabled(isWorking)
                    Button("Run once", systemImage: "play.fill") {
                        runOnce()
                    }
                    .disabled(isWorking)
                    if isLoaded {
                        Label("Resident", systemImage: "memorychip.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                    }
                    if isWarming {
                        ProgressView().controlSize(.small)
                        Text("Warming model…")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if isRunningOnce {
                        ProgressView().controlSize(.small)
                        Text("Measuring one run…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if let error = result.error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Model load: \(result.modelLoadTime.formatted(.number.precision(.fractionLength(2))))s · prompt: \(result.medianPromptTime.formatted(.number.precision(.fractionLength(2))))s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(result.tasks.enumerated()), id: \.offset) { _, task in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(task.text).fontWeight(.medium)
                            }
                            let details = [
                                task.requester.map { "Asked by \($0)" },
                                task.assignee.map { "Assigned to \($0)" },
                                task.dueDate.map { "Due: \($0)" }
                            ].compactMap { $0 }
                            if !details.isEmpty {
                                Text(details.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let evidence = task.evidence {
                                Text("“\(evidence)”")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    if result.tasks.isEmpty {
                        Text("No tasks extracted.").foregroundStyle(.secondary)
                    }
                    Divider()
                    Text("Measured runs").font(.caption.bold())
                    ForEach(Array(result.samples.enumerated()), id: \.offset) { index, sample in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("#\(index + 1)")
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 28, alignment: .leading)
                                Metric(value: sample.wallTime.formatted(.number.precision(.fractionLength(2))) + "s", label: "wall")
                                Metric(value: sample.timeToFirstToken.formatted(.number.precision(.fractionLength(2))) + "s", label: "TTFT")
                                Metric(value: sample.tokensPerSecond.formatted(.number.precision(.fractionLength(1))), label: "tok/s")
                                Text("\(sample.tasks.count) tasks")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("thermal \(sample.thermalStateBefore)→\(sample.thermalStateAfter)")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                            }
                            Text(sample.tasks.map(\.text).joined(separator: " • "))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                    Divider()
                    Text(result.rawOutput)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 12) {
                Text(result.error == nil ? "#\(rank)" : "!")
                    .font(.headline.monospacedDigit())
                    .frame(width: 30, height: 30)
                    .background(result.error == nil ? Color.accentColor.opacity(0.15) : Color.red.opacity(0.15))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.model).fontWeight(.semibold)
                    if result.error == nil {
                        Text("\(result.taskCount) tasks · \(result.samples.count) measured runs")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Failed").font(.caption).foregroundStyle(.red)
                    }
                }
                Spacer()
                if result.error == nil {
                    Metric(value: result.medianWallTime.formatted(.number.precision(.fractionLength(2))) + "s", label: "wall")
                    Metric(value: result.medianTimeToFirstToken.formatted(.number.precision(.fractionLength(2))) + "s", label: "TTFT")
                    Metric(value: result.medianTokensPerSecond.formatted(.number.precision(.fractionLength(1))), label: "tok/s")
                }
            }
            .contentShape(Rectangle())
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct Metric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value).font(.system(.body, design: .rounded).monospacedDigit()).fontWeight(.semibold)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(minWidth: 54, alignment: .trailing)
    }
}

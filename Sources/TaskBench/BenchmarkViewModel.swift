import AppKit
import Foundation
import MLXTaskExtractor
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class BenchmarkViewModel: ObservableObject {
    struct ModelOption: Identifiable, Hashable {
        let id: String
        let name: String
        let specification: String
    }

    static let modelCatalog = [
        ModelOption(
            id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
            name: "Llama 3.2 Instruct",
            specification: "1B · 4-bit · baseline"
        ),
        ModelOption(
            id: "mlx-community/Qwen3-0.6B-4bit",
            name: "Qwen 3",
            specification: "0.6B · 4-bit"
        ),
        ModelOption(
            id: "mlx-community/gemma-3-270m-it-4bit",
            name: "Gemma 3 IT",
            specification: "270M · 4-bit"
        ),
        ModelOption(
            id: "mlx-community/gemma-3-1b-it-qat-4bit",
            name: "Gemma 3 IT QAT",
            specification: "1B · 4-bit"
        ),
        ModelOption(
            id: "mlx-community/Qwen3-1.7B-4bit",
            name: "Qwen 3",
            specification: "1.7B · 4-bit"
        )
    ]

    @Published var screenshot: NSImage?
    @Published var recognizedText = ""
    @Published var selectedModelIDs = [
        "mlx-community/Llama-3.2-1B-Instruct-4bit",
        "mlx-community/Qwen3-0.6B-4bit",
        "mlx-community/gemma-3-270m-it-4bit",
        "mlx-community/gemma-3-1b-it-qat-4bit"
    ]
    @Published var runs = 3
    @Published var warmUp = true
    @Published var results: [BenchmarkResult] = []
    @Published var status = "Capture a screen or choose an image to begin."
    @Published var isWorking = false
    @Published var ocrDuration: TimeInterval?
    @Published private(set) var logs: [BenchmarkLogEntry] = []
    @Published private(set) var warmingModel: String?
    @Published private(set) var runningOnceModel: String?
    @Published private(set) var loadedModelID: String?

    private let runner = MLXRunner()
    private var benchmarkStartedAt: Date?
    private var benchmarkFinishedAt: Date?
    private var benchmarkConfiguration: (models: [String], runs: Int, warmUp: Bool)?
    private var benchmarkInput: (ocrText: String, ocrDuration: TimeInterval?, screenshotSize: CGSize?)?
    private var captureLogs: [BenchmarkLogEntry] = []

    var models: [String] {
        selectedModelIDs
    }

    var availableCatalogModels: [ModelOption] {
        Self.modelCatalog.filter { !selectedModelIDs.contains($0.id) }
    }

    func modelOption(for id: String) -> ModelOption? {
        Self.modelCatalog.first { $0.id == id }
    }

    @discardableResult
    func addModel(_ id: String) -> Bool {
        let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !selectedModelIDs.contains(normalized) else { return false }
        selectedModelIDs.append(normalized)
        return true
    }

    func removeModel(_ id: String) {
        selectedModelIDs.removeAll { $0 == id }
    }

    func capture() async {
        await performCapture {
            try await ScreenshotService.captureMainDisplay()
        }
    }

    func chooseImage() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK,
              let url = panel.url,
              let image = NSImage(contentsOf: url),
              let cgImage = image.cgImageValue else { return }
        logs = []
        captureLogs = []
        results = []
        benchmarkStartedAt = nil
        benchmarkFinishedAt = nil
        benchmarkConfiguration = nil
        benchmarkInput = nil
        await runner.discardInteractiveModel()
        loadedModelID = nil
        await process(image: cgImage)
    }

    func useRecommendedModels() {
        let memoryGB = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        var recommended = [
            "mlx-community/gemma-3-270m-it-4bit",
            "mlx-community/Qwen3-0.6B-4bit",
            "mlx-community/gemma-3-1b-it-qat-4bit",
            "mlx-community/Llama-3.2-1B-Instruct-4bit"
        ]
        if memoryGB >= 16 {
            recommended.append("mlx-community/Qwen3-1.7B-4bit")
        }
        selectedModelIDs = recommended
        updateStatus("Selected \(recommended.count) MLX models for this \(memoryGB) GB Mac.")
    }

    func runBenchmarks() async {
        let selectedModels = models
        let selectedRuns = runs
        let selectedWarmUp = warmUp
        let selectedText = recognizedText
        guard !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            updateStatus("Capture a screen or choose an image first.", level: "warning")
            return
        }
        guard !selectedModels.isEmpty else {
            updateStatus("Add at least one model.", level: "warning")
            return
        }

        await runner.discardInteractiveModel()
        loadedModelID = nil
        isWorking = true
        results = []
        logs = captureLogs
        benchmarkStartedAt = Date()
        benchmarkFinishedAt = nil
        benchmarkConfiguration = (selectedModels, selectedRuns, selectedWarmUp)
        benchmarkInput = (selectedText, ocrDuration, screenshot?.size)
        logs.append(BenchmarkLogEntry(
            timestamp: benchmarkStartedAt!,
            level: "info",
            message: "Started benchmark with \(selectedModels.count) models, \(selectedRuns) measured runs, warm-up \(selectedWarmUp ? "enabled" : "disabled").",
            model: nil
        ))
        defer { isWorking = false }

        for (index, model) in selectedModels.enumerated() {
            updateStatus("Benchmarking \(model) (\(index + 1) of \(selectedModels.count))…", model: model)
            do {
                let run = try await runner.benchmark(
                    modelID: model,
                    text: selectedText,
                    runs: selectedRuns,
                    warmUp: selectedWarmUp
                ) { [weak self] update in
                    self?.updateStatus(update, model: model)
                }
                results.append(BenchmarkResult(
                    model: model,
                    modelLoadTime: run.loadTime,
                    samples: run.samples,
                    error: nil
                ))
                loadedModelID = model
                updateStatus("Completed \(model).", model: model)
            } catch {
                results.append(BenchmarkResult(
                    model: model,
                    modelLoadTime: 0,
                    samples: [],
                    error: error.localizedDescription
                ))
                updateStatus("Failed: \(error.localizedDescription)", level: "error", model: model)
            }
        }
        results.sort {
            if $0.error != nil { return false }
            if $1.error != nil { return true }
            return $0.medianWallTime < $1.medianWallTime
        }
        loadedModelID = await runner.loadedModelID
        benchmarkFinishedAt = Date()
        updateStatus("Finished \(selectedModels.count) model benchmarks.")
    }

    func exportResults() {
        guard !results.isEmpty else {
            updateStatus("Run a benchmark before exporting.", level: "warning")
            return
        }
        guard let configuration = benchmarkConfiguration else {
            updateStatus("The benchmark configuration is unavailable; run the benchmark again.", level: "error")
            return
        }
        guard let input = benchmarkInput else {
            updateStatus("The benchmark input is unavailable; run the benchmark again.", level: "error")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = Self.defaultExportFilename
        panel.title = "Export TaskBench results and logs"
        panel.message = "Saves OCR input, configuration, system details, logs, timings, tasks, and raw model output."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let report = BenchmarkExport.make(
                models: configuration.models,
                runs: configuration.runs,
                warmUp: configuration.warmUp,
                pipelineVersion: MLXRunner.pipelineVersion,
                maxOutputTokens: MLXRunner.maxOutputTokens,
                taskInstructions: MLXRunner.taskInstructions,
                taskJSONSchema: MLXRunner.taskSchema,
                ocrText: input.ocrText,
                ocrDuration: input.ocrDuration,
                screenshotSize: input.screenshotSize,
                logs: logs,
                results: results,
                startedAt: benchmarkStartedAt,
                finishedAt: benchmarkFinishedAt
            )
            try report.encoded().write(to: url, options: .atomic)
            updateStatus("Exported results to \(url.lastPathComponent).")
        } catch {
            updateStatus("Export failed: \(error.localizedDescription)", level: "error")
        }
    }

    func warmModel(modelID: String) async {
        guard !isWorking else { return }
        guard let input = benchmarkInput else {
            updateStatus("Run the full benchmark before warming a model.", level: "warning")
            return
        }
        guard results.contains(where: { $0.model == modelID }) else {
            updateStatus("No benchmark result exists for \(modelID).", level: "error", model: modelID)
            return
        }

        isWorking = true
        warmingModel = modelID
        updateStatus("Re-warming \(modelID)…", model: modelID)
        defer {
            warmingModel = nil
            isWorking = false
        }

        do {
            let loadTime = try await runner.warmModel(
                modelID: modelID,
                text: input.ocrText
            ) { [weak self] update in
                self?.updateStatus(update, model: modelID)
            }
            loadedModelID = modelID
            let loadDescription = loadTime > 0
                ? " after loading in \(loadTime.formatted(.number.precision(.fractionLength(2))))s"
                : ""
            updateStatus("\(modelID) is warm and resident\(loadDescription).", model: modelID)
        } catch {
            loadedModelID = await runner.loadedModelID
            updateStatus(
                "Model warm-up failed: \(error.localizedDescription)",
                level: "error",
                model: modelID
            )
        }
    }

    func runOnce(modelID: String) async {
        guard !isWorking else { return }
        guard let input = benchmarkInput else {
            updateStatus("Run the full benchmark before starting an interactive run.", level: "warning")
            return
        }
        guard let resultIndex = results.firstIndex(where: { $0.model == modelID }) else {
            updateStatus("No benchmark result exists for \(modelID).", level: "error", model: modelID)
            return
        }

        isWorking = true
        runningOnceModel = modelID
        updateStatus("Running one measured extraction with \(modelID)…", model: modelID)
        defer {
            runningOnceModel = nil
            isWorking = false
        }

        do {
            let run = try await runner.runOnce(
                modelID: modelID,
                text: input.ocrText
            ) { [weak self] update in
                self?.updateStatus(update, model: modelID)
            }
            guard let sample = run.samples.first else { return }
            results[resultIndex] = results[resultIndex].appending(
                sample,
                additionalLoadTime: run.loadTime
            )
            loadedModelID = modelID
            updateStatus(
                "Measured run completed in \(sample.wallTime.formatted(.number.precision(.fractionLength(2))))s with \(sample.tasks.count) tasks; thermal \(sample.thermalStateBefore) → \(sample.thermalStateAfter).",
                model: modelID
            )
        } catch {
            loadedModelID = await runner.loadedModelID
            updateStatus(
                "Measured run failed: \(error.localizedDescription)",
                level: "error",
                model: modelID
            )
        }
    }

    private func performCapture(_ operation: () async throws -> CGImage) async {
        logs = []
        captureLogs = []
        results = []
        benchmarkStartedAt = nil
        benchmarkFinishedAt = nil
        benchmarkConfiguration = nil
        benchmarkInput = nil
        await runner.discardInteractiveModel()
        loadedModelID = nil
        isWorking = true
        updateStatus("Capturing screen…")
        defer { isWorking = false }
        do {
            try await process(image: operation())
        } catch {
            updateStatus("Capture failed: \(error.localizedDescription)", level: "error")
        }
    }

    private func process(image: CGImage) async {
        defer { captureLogs = logs }
        screenshot = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        recognizedText = ""
        ocrDuration = nil
        updateStatus("Recognizing text with Vision…")
        let start = ContinuousClock.now
        do {
            let result = try await VisionOCR.recognizeText(in: image)
            recognizedText = result.text
            ocrDuration = start.duration(to: .now).seconds
            if let recoveredFrom = result.recoveredFrom {
                updateStatus(
                    "Vision OCR recovered with \(result.strategy) after: \(recoveredFrom)",
                    level: "warning"
                )
            }
            updateStatus(
                recognizedText.isEmpty
                    ? "No text was recognized using Vision OCR \(result.strategy)."
                    : "OCR found \(recognizedText.count) characters using Vision OCR \(result.strategy)."
            )
        } catch {
            updateStatus("OCR failed: \(error.localizedDescription)", level: "error")
        }
    }

    private func updateStatus(_ message: String, level: String = "info", model: String? = nil) {
        status = message
        logs.append(BenchmarkLogEntry(timestamp: Date(), level: level, message: message, model: model))
    }

    private static var defaultExportFilename: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "taskbench-\(formatter.string(from: Date())).json"
    }
}

private extension Duration {
    var seconds: TimeInterval {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

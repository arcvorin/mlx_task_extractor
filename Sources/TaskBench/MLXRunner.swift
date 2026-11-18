import Foundation
import MLXTaskExtractor

actor MLXRunner {
    nonisolated static let pipelineVersion = TaskExtractor.pipelineVersion
    nonisolated static let maxOutputTokens = TaskExtractor.defaultMaxOutputTokens
    nonisolated static let taskInstructions = TaskExtractor.taskInstructions
    nonisolated static let taskSchema = TaskExtractor.taskSchema

    struct ModelRun: Sendable {
        let loadTime: TimeInterval
        let samples: [BenchmarkSample]
    }

    private var interactiveModel: (id: String, extractor: TaskExtractor)?

    var loadedModelID: String? { interactiveModel?.id }

    func discardInteractiveModel() async {
        if let interactiveModel {
            await interactiveModel.extractor.unload()
        }
        interactiveModel = nil
    }

    func benchmark(
        modelID: String,
        text: String,
        runs: Int,
        warmUp: Bool,
        progress: @MainActor @escaping (String) -> Void
    ) async throws -> ModelRun {
        await discardInteractiveModel()
        let extractor = TaskExtractor(configuration: .init(
            modelID: modelID,
            maxOutputTokens: Self.maxOutputTokens
        ))
        await progress("Downloading or loading \(shortName(modelID))…")
        let loadTime = try await extractor.preload()
        interactiveModel = (modelID, extractor)

        if warmUp {
            await progress("Warming up \(shortName(modelID))…")
            _ = try await extractor.warmUp(text: text)
        }

        var samples: [BenchmarkSample] = []
        for run in 1...runs {
            await progress("\(shortName(modelID)): run \(run) of \(runs)…")
            samples.append(sample(from: try await extractor.extract(from: text)))
        }
        return ModelRun(loadTime: loadTime, samples: samples)
    }

    func warmModel(
        modelID: String,
        text: String,
        progress: @MainActor @escaping (String) -> Void
    ) async throws -> TimeInterval {
        let (extractor, loadTime) = try await prepareInteractiveModel(
            modelID: modelID,
            progress: progress
        )
        await progress("Re-warming \(shortName(modelID))…")
        _ = try await extractor.warmUp(text: text)
        return loadTime
    }

    func runOnce(
        modelID: String,
        text: String,
        progress: @MainActor @escaping (String) -> Void
    ) async throws -> ModelRun {
        let (extractor, loadTime) = try await prepareInteractiveModel(
            modelID: modelID,
            progress: progress
        )
        await progress("Running one measured extraction with \(shortName(modelID))…")
        let measured = sample(from: try await extractor.extract(from: text))
        return ModelRun(loadTime: loadTime, samples: [measured])
    }

    private func prepareInteractiveModel(
        modelID: String,
        progress: @MainActor @escaping (String) -> Void
    ) async throws -> (TaskExtractor, TimeInterval) {
        let extractor: TaskExtractor
        let loadTime: TimeInterval
        if let interactiveModel, interactiveModel.id == modelID {
            extractor = interactiveModel.extractor
            loadTime = 0
            await progress("Using loaded \(shortName(modelID))…")
        } else {
            await discardInteractiveModel()
            extractor = TaskExtractor(configuration: .init(
                modelID: modelID,
                maxOutputTokens: Self.maxOutputTokens
            ))
            await progress("Loading \(shortName(modelID)) for interactive use…")
            loadTime = try await extractor.preload()
            interactiveModel = (modelID, extractor)
        }
        return (extractor, loadTime)
    }

    private func sample(from result: TaskExtractionResult) -> BenchmarkSample {
        let metrics = result.metrics
        return BenchmarkSample(
            wallTime: metrics.wallSeconds,
            timeToFirstToken: metrics.timeToFirstTokenSeconds,
            promptTime: metrics.timeToFirstTokenSeconds,
            generationTime: max(metrics.wallSeconds - metrics.timeToFirstTokenSeconds, 0.000_001),
            promptTokens: metrics.promptTokens,
            outputTokens: metrics.outputTokens,
            tokensPerSecond: metrics.tokensPerSecond,
            tasks: result.tasks,
            rawOutput: result.rawOutput,
            thermalStateBefore: metrics.thermalStateBefore,
            thermalStateAfter: metrics.thermalStateAfter
        )
    }

    private func shortName(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }
}

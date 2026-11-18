import Foundation
import MLXTaskExtractor

struct BenchmarkSample: Sendable {
    let wallTime: TimeInterval
    let timeToFirstToken: TimeInterval
    let promptTime: TimeInterval
    let generationTime: TimeInterval
    let promptTokens: Int
    let outputTokens: Int
    let tokensPerSecond: Double
    let tasks: [ExtractedTask]
    let rawOutput: String
    let thermalStateBefore: String
    let thermalStateAfter: String

    init(
        wallTime: TimeInterval,
        timeToFirstToken: TimeInterval,
        promptTime: TimeInterval,
        generationTime: TimeInterval,
        promptTokens: Int,
        outputTokens: Int,
        tokensPerSecond: Double,
        tasks: [ExtractedTask],
        rawOutput: String,
        thermalStateBefore: String = "unknown",
        thermalStateAfter: String = "unknown"
    ) {
        self.wallTime = wallTime
        self.timeToFirstToken = timeToFirstToken
        self.promptTime = promptTime
        self.generationTime = generationTime
        self.promptTokens = promptTokens
        self.outputTokens = outputTokens
        self.tokensPerSecond = tokensPerSecond
        self.tasks = tasks
        self.rawOutput = rawOutput
        self.thermalStateBefore = thermalStateBefore
        self.thermalStateAfter = thermalStateAfter
    }
}

extension ProcessInfo.ThermalState {
    var taskBenchName: String {
        switch self {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

struct BenchmarkResult: Identifiable, Sendable {
    let id: UUID
    let model: String
    let modelLoadTime: TimeInterval
    let samples: [BenchmarkSample]
    let error: String?

    init(
        id: UUID = UUID(),
        model: String,
        modelLoadTime: TimeInterval,
        samples: [BenchmarkSample],
        error: String?
    ) {
        self.id = id
        self.model = model
        self.modelLoadTime = modelLoadTime
        self.samples = samples
        self.error = error
    }

    func appending(_ sample: BenchmarkSample, additionalLoadTime: TimeInterval) -> Self {
        Self(
            id: id,
            model: model,
            modelLoadTime: modelLoadTime > 0 ? modelLoadTime : additionalLoadTime,
            samples: samples + [sample],
            error: nil
        )
    }

    var medianWallTime: TimeInterval { samples.map(\.wallTime).median }
    var medianTimeToFirstToken: TimeInterval { samples.map(\.timeToFirstToken).median }
    var medianPromptTime: TimeInterval { samples.map(\.promptTime).median }
    var medianTokensPerSecond: Double { samples.map(\.tokensPerSecond).median }
    var taskCount: Int { tasks.count }
    var tasks: [ExtractedTask] { samples.last?.tasks ?? [] }
    var rawOutput: String { samples.last?.rawOutput ?? "" }
}

extension Array where Element == Double {
    var median: Double {
        guard !isEmpty else { return 0 }
        let values = sorted()
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[middle - 1] + values[middle]) / 2
        }
        return values[middle]
    }
}

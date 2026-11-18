import Foundation
import MLXTaskExtractor

struct BenchmarkLogEntry: Codable, Sendable {
    let timestamp: Date
    let level: String
    let message: String
    let model: String?
}

struct BenchmarkExport: Codable, Sendable {
    let formatVersion: Int
    let exportedAt: Date
    let benchmarkStartedAt: Date?
    let benchmarkFinishedAt: Date?
    let system: SystemInfo
    let configuration: Configuration
    let input: Input
    let logs: [BenchmarkLogEntry]
    let results: [Result]

    struct SystemInfo: Codable, Sendable {
        let operatingSystem: String
        let architecture: String
        let physicalMemoryBytes: UInt64
        let processorCount: Int
        let activeProcessorCount: Int
        let thermalStateAtExport: String
    }

    struct Configuration: Codable, Sendable {
        let models: [String]
        let measuredRuns: Int
        let warmUp: Bool
        let pipelineVersion: Int
        let maxOutputTokens: Int
        let taskInstructions: String
        let taskJSONSchema: String
    }

    struct Input: Codable, Sendable {
        let ocrText: String
        let ocrDurationSeconds: TimeInterval?
        let screenshotWidthPixels: Int?
        let screenshotHeightPixels: Int?
    }

    struct Result: Codable, Sendable {
        let model: String
        let succeeded: Bool
        let error: String?
        let modelLoadSeconds: TimeInterval
        let summary: Summary?
        let samples: [Sample]
    }

    struct Summary: Codable, Sendable {
        let medianWallSeconds: TimeInterval
        let medianTimeToFirstTokenSeconds: TimeInterval
        let medianPromptSeconds: TimeInterval
        let medianTokensPerSecond: Double
        let taskCount: Int
    }

    struct Sample: Codable, Sendable {
        let wallSeconds: TimeInterval
        let timeToFirstTokenSeconds: TimeInterval
        let promptSeconds: TimeInterval
        let generationSeconds: TimeInterval
        let promptTokens: Int
        let outputTokens: Int
        let tokensPerSecond: Double
        let tasks: [ExtractedTask]
        let rawOutput: String
        let thermalStateBefore: String
        let thermalStateAfter: String
    }

    static func make(
        models: [String],
        runs: Int,
        warmUp: Bool,
        pipelineVersion: Int,
        maxOutputTokens: Int,
        taskInstructions: String,
        taskJSONSchema: String,
        ocrText: String,
        ocrDuration: TimeInterval?,
        screenshotSize: CGSize?,
        logs: [BenchmarkLogEntry],
        results: [BenchmarkResult],
        startedAt: Date?,
        finishedAt: Date?
    ) -> Self {
        let process = ProcessInfo.processInfo
        return Self(
            formatVersion: 1,
            exportedAt: Date(),
            benchmarkStartedAt: startedAt,
            benchmarkFinishedAt: finishedAt,
            system: SystemInfo(
                operatingSystem: process.operatingSystemVersionString,
                architecture: architecture,
                physicalMemoryBytes: process.physicalMemory,
                processorCount: process.processorCount,
                activeProcessorCount: process.activeProcessorCount,
                thermalStateAtExport: process.thermalState.taskBenchName
            ),
            configuration: Configuration(
                models: models,
                measuredRuns: runs,
                warmUp: warmUp,
                pipelineVersion: pipelineVersion,
                maxOutputTokens: maxOutputTokens,
                taskInstructions: taskInstructions,
                taskJSONSchema: taskJSONSchema
            ),
            input: Input(
                ocrText: ocrText,
                ocrDurationSeconds: ocrDuration,
                screenshotWidthPixels: screenshotSize.map { Int($0.width) },
                screenshotHeightPixels: screenshotSize.map { Int($0.height) }
            ),
            logs: logs,
            results: results.map { result in
                Result(
                    model: result.model,
                    succeeded: result.error == nil,
                    error: result.error,
                    modelLoadSeconds: result.modelLoadTime,
                    summary: result.error == nil ? Summary(
                        medianWallSeconds: result.medianWallTime,
                        medianTimeToFirstTokenSeconds: result.medianTimeToFirstToken,
                        medianPromptSeconds: result.medianPromptTime,
                        medianTokensPerSecond: result.medianTokensPerSecond,
                        taskCount: result.taskCount
                    ) : nil,
                    samples: result.samples.map { sample in
                        Sample(
                            wallSeconds: sample.wallTime,
                            timeToFirstTokenSeconds: sample.timeToFirstToken,
                            promptSeconds: sample.promptTime,
                            generationSeconds: sample.generationTime,
                            promptTokens: sample.promptTokens,
                            outputTokens: sample.outputTokens,
                            tokensPerSecond: sample.tokensPerSecond,
                            tasks: sample.tasks,
                            rawOutput: sample.rawOutput,
                            thermalStateBefore: sample.thermalStateBefore,
                            thermalStateAfter: sample.thermalStateAfter
                        )
                    }
                )
            }
        )
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}

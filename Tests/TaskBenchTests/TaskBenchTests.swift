import Foundation
import MLXTaskExtractor
import Testing
@testable import TaskBench

@Suite("TaskBench support")
struct TaskBenchTests {
    @Test("Adds, deduplicates, and removes model tags")
    @MainActor
    func managesModelSelection() {
        let viewModel = BenchmarkViewModel()
        let custom = "mlx-community/Custom-Model-4bit"

        #expect(viewModel.addModel(custom))
        #expect(!viewModel.addModel("  \(custom)  "))
        #expect(viewModel.models.last == custom)

        viewModel.removeModel(custom)
        #expect(!viewModel.models.contains(custom))
    }

    @Test("Exports complete benchmark diagnostics as JSON")
    func benchmarkExport() throws {
        let task = ExtractedTask(text: "Fix endpoint", evidence: "404")
        let sample = BenchmarkSample(
            wallTime: 1.2,
            timeToFirstToken: 0.3,
            promptTime: 0.3,
            generationTime: 0.9,
            promptTokens: 20,
            outputTokens: 10,
            tokensPerSecond: 11.1,
            tasks: [task],
            rawOutput: #"{"tasks":[{"text":"Fix endpoint"}]}"#
        )
        let result = BenchmarkResult(model: "test/model", modelLoadTime: 2, samples: [sample], error: nil)
        let report = BenchmarkExport.make(
            models: ["test/model"],
            runs: 1,
            warmUp: true,
            pipelineVersion: 11,
            maxOutputTokens: 600,
            taskInstructions: "Extract tasks",
            taskJSONSchema: #"{"type":"object"}"#,
            ocrText: "endpoint returns 404",
            ocrDuration: 0.1,
            screenshotSize: .init(width: 1200, height: 800),
            logs: [.init(timestamp: Date(timeIntervalSince1970: 0), level: "info", message: "done", model: nil)],
            results: [result],
            startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 2)
        )
        let data = try report.encoded()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BenchmarkExport.self, from: data)
        #expect(decoded.configuration.pipelineVersion == 11)
        #expect(decoded.results.first?.samples.first?.tasks.first?.text == "Fix endpoint")
        #expect(decoded.logs.count == 1)
    }

    @Test("Appends an interactive sample without replacing history")
    func appendsInteractiveSample() {
        let sample = BenchmarkSample(
            wallTime: 1,
            timeToFirstToken: 0.2,
            promptTime: 0.2,
            generationTime: 0.8,
            promptTokens: 10,
            outputTokens: 5,
            tokensPerSecond: 6.25,
            tasks: [],
            rawOutput: #"{"tasks":[]}"#
        )
        let original = BenchmarkResult(
            model: "test/model",
            modelLoadTime: 2,
            samples: [sample],
            error: nil
        )
        let updated = original.appending(sample, additionalLoadTime: 0)
        #expect(updated.id == original.id)
        #expect(updated.samples.count == 2)
    }

    @Test("Median handles odd and even samples")
    func median() {
        #expect([3.0, 1.0, 2.0].median == 2.0)
        #expect([4.0, 1.0, 3.0, 2.0].median == 2.5)
    }
}

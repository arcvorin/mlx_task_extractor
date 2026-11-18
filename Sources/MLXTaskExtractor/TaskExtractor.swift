import CoreGraphics
import Foundation
import HuggingFace
import MLXGuidedGeneration
import MLXLLM
import MLXLMCommon
import Tokenizers

public actor TaskExtractor {
    public static let pipelineVersion = 11
    public static let defaultModelID = "mlx-community/Llama-3.2-1B-Instruct-4bit"
    public static let defaultMaxOutputTokens = 600
    public static let taskInstructions = """
    Extract explicit, actionable tasks from the screen text below. Ignore navigation, labels, completed work, and vague ideas. Never invent details. Use null for missing due dates or assignees. Quote the source text in evidence.
    Return JSON only. /no_think
    """
    public static let taskSchema = #"""
    {
      "type": "object",
      "properties": {
        "tasks": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "text": { "type": "string" },
              "dueDate": { "type": ["string", "null"] },
              "assignee": { "type": ["string", "null"] },
              "evidence": { "type": ["string", "null"] }
            },
            "required": ["text"],
            "additionalProperties": false
          }
        }
      },
      "required": ["tasks"],
      "additionalProperties": false
    }
    """#

    public struct Configuration: Hashable, Sendable {
        public var modelID: String
        public var maxOutputTokens: Int

        public init(
            modelID: String = TaskExtractor.defaultModelID,
            maxOutputTokens: Int = TaskExtractor.defaultMaxOutputTokens
        ) {
            self.modelID = modelID
            self.maxOutputTokens = maxOutputTokens
        }
    }

    public let configuration: Configuration

    private var container: ModelContainer?
    private var grammarTemplate: GrammarTemplate?
    private var grammarCannotClone = false

    private struct GrammarTemplate: Sendable {
        let constraint: GrammarConstraint
        let vocabSize: Int
    }

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    @discardableResult
    public func preload() async throws -> TimeInterval {
        if container != nil { return 0 }
        let start = ContinuousClock.now
        container = try await loadModelContainer(
            from: HuggingFaceHubDownloader(),
            using: HuggingFaceTokenizerLoader(),
            configuration: ModelConfiguration(id: configuration.modelID)
        )
        return start.duration(to: .now).seconds
    }

    public func unload() {
        container = nil
        grammarTemplate = nil
        grammarCannotClone = false
    }

    @discardableResult
    public func warmUp(text: String) async throws -> TaskExtractionResult {
        try await extract(from: text)
    }

    public func extract(from image: CGImage) async throws -> ScreenshotTaskExtractionResult {
        let start = ContinuousClock.now
        let ocr = try await VisionOCR.recognizeText(in: image)
        let ocrDuration = start.duration(to: .now).seconds
        let extraction = try await extract(from: ocr.text)
        return ScreenshotTaskExtractionResult(
            ocr: ocr,
            ocrDurationSeconds: ocrDuration,
            extraction: extraction
        )
    }

    public func extract(from text: String) async throws -> TaskExtractionResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TaskExtractionError.emptyInput
        }
        let loadTime = try await preload()
        guard let container else { throw TaskExtractionError.modelUnavailable }
        let thermalBefore = ProcessInfo.processInfo.thermalState.taskExtractorName
        let prompt = """
        \(Self.taskInstructions)

        \(text)
        """
        let generated = try await generate(
            container: container,
            prompt: prompt,
            maxTokens: configuration.maxOutputTokens
        )
        let tasks: [ExtractedTask]
        do {
            tasks = TaskProvenanceEnricher.enrich(
                try TaskOutputParser.parse(generated.text),
                sourceText: text
            )
        } catch {
            throw TaskExtractionError.invalidOutput(generated.text)
        }
        let generationTime = max(generated.wallTime - generated.timeToFirstToken, 0.000_001)
        return TaskExtractionResult(
            modelID: configuration.modelID,
            tasks: tasks,
            inputText: text,
            rawOutput: generated.text,
            metrics: TaskExtractionMetrics(
                modelLoadSeconds: loadTime,
                wallSeconds: generated.wallTime,
                timeToFirstTokenSeconds: generated.timeToFirstToken,
                promptTokens: generated.promptTokens,
                outputTokens: generated.outputTokens,
                tokensPerSecond: Double(generated.outputTokens) / generationTime,
                thermalStateBefore: thermalBefore,
                thermalStateAfter: ProcessInfo.processInfo.thermalState.taskExtractorName
            )
        )
    }

    private func generate(
        container: ModelContainer,
        prompt: String,
        maxTokens: Int
    ) async throws -> GeneratedOutput {
        let grammar = try await makeConstraint(container: container)
        return try await container.perform { context in
            let start = ContinuousClock.now
            let tokenizer = context.tokenizer
            let input = try await context.processor.prepare(input: UserInput(prompt: prompt))
            let promptTokens = input.text.tokens.size
            let structuralReserve = CompletionReserve.estimate(
                schemaJSON: Self.taskSchema,
                tokenizer: tokenizer
            )
            let completionReserve = max(structuralReserve * 3, maxTokens / 4)
            let hardReserve = structuralReserve * 8
            let closingBias = ClosingTokenBias.compute(
                tokenizer: tokenizer,
                eosTokenId: tokenizer.eosTokenId
            )
            let (whitespaceBias, whitespaceTokenIDs) = WhitespaceTokenBias.compute(
                tokenizer: tokenizer
            )
            var output = ""
            var firstTokenAt: Duration?
            let outputTokens: Int
            do {
                outputTokens = try GuidedGenerationLoop.run(
                    input: input,
                    context: context,
                    constraint: grammar.constraint,
                    maxTokens: maxTokens,
                    vocabSize: grammar.vocabSize,
                    completionReserve: completionReserve,
                    hardReserve: hardReserve,
                    closingBias: closingBias,
                    whitespaceBias: whitespaceBias,
                    whitespaceTokenIDs: whitespaceTokenIDs
                ) { delta in
                    if firstTokenAt == nil, !delta.isEmpty {
                        firstTokenAt = start.duration(to: .now)
                    }
                    output += delta
                    return true
                }
            } catch GuidedGenerationError.incompleteOutput {
                throw TaskExtractionError.incompleteOutput(maxTokens: maxTokens, output: output)
            } catch GuidedGenerationError.prematureEOS {
                throw TaskExtractionError.prematureEOS(output)
            }
            let wallTime = start.duration(to: .now).seconds
            return GeneratedOutput(
                text: output,
                wallTime: wallTime,
                timeToFirstToken: firstTokenAt?.seconds ?? wallTime,
                promptTokens: promptTokens,
                outputTokens: outputTokens
            )
        }
    }

    private func makeConstraint(container: ModelContainer) async throws -> GrammarTemplate {
        if grammarCannotClone { return try await compileConstraint(container: container) }
        if let grammarTemplate {
            do {
                return GrammarTemplate(
                    constraint: try grammarTemplate.constraint.clone(),
                    vocabSize: grammarTemplate.vocabSize
                )
            } catch GrammarError.forkFailed {
                self.grammarTemplate = nil
                grammarCannotClone = true
                return try await compileConstraint(container: container)
            }
        }
        let template = try await compileConstraint(container: container)
        do {
            let clone = try template.constraint.clone()
            grammarTemplate = template
            return GrammarTemplate(constraint: clone, vocabSize: template.vocabSize)
        } catch GrammarError.forkFailed {
            grammarCannotClone = true
            return template
        }
    }

    private func compileConstraint(container: ModelContainer) async throws -> GrammarTemplate {
        try await container.perform { context in
            let tokenizer = context.tokenizer
            let vocab = TokenizerVocabExtractor.extractForGrammar(from: tokenizer)
            let grammarTokenizer = try GrammarTokenizer(
                vocab: vocab.vocab,
                vocabType: vocab.vocabType,
                eosTokenId: Int32(tokenizer.eosTokenId ?? 0)
            )
            return GrammarTemplate(
                constraint: try GrammarConstraint(
                    tokenizer: grammarTokenizer,
                    jsonSchema: Self.taskSchema,
                    fastForward: true,
                    hostTokenizer: tokenizer
                ),
                vocabSize: grammarTokenizer.vocabSize
            )
        }
    }

    private struct GeneratedOutput: Sendable {
        let text: String
        let wallTime: TimeInterval
        let timeToFirstToken: TimeInterval
        let promptTokens: Int
        let outputTokens: Int
    }
}

public enum TaskExtractionError: LocalizedError {
    case emptyInput
    case modelUnavailable
    case invalidOutput(String)
    case incompleteOutput(maxTokens: Int, output: String)
    case prematureEOS(String)

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            "The input text is empty."
        case .modelUnavailable:
            "The MLX model could not be loaded."
        case .invalidOutput(let output):
            "The constrained output could not be decoded. Raw output:\n\(preview(output))"
        case .incompleteOutput(let maxTokens, let output):
            "The model used the \(maxTokens)-token limit before it could close the task JSON. Partial output:\n\(preview(output))"
        case .prematureEOS(let output):
            "The model stopped before it could close the task JSON. Partial output:\n\(preview(output))"
        }
    }

    private func preview(_ output: String) -> String {
        output.isEmpty ? "<empty output>" : String(output.prefix(800))
    }
}

private extension Duration {
    var seconds: TimeInterval {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

private extension ProcessInfo.ThermalState {
    var taskExtractorName: String {
        switch self {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

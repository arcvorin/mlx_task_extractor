import Foundation

public struct ExtractedTask: Codable, Hashable, Sendable {
    public let text: String
    public let requester: String?
    public let dueDate: String?
    public let assignee: String?
    public let evidence: String?

    public init(
        text: String,
        requester: String? = nil,
        dueDate: String? = nil,
        assignee: String? = nil,
        evidence: String? = nil
    ) {
        self.text = text
        self.requester = requester
        self.dueDate = dueDate
        self.assignee = assignee
        self.evidence = evidence
    }
}

public struct TaskExtractionMetrics: Codable, Hashable, Sendable {
    public let modelLoadSeconds: TimeInterval
    public let wallSeconds: TimeInterval
    public let timeToFirstTokenSeconds: TimeInterval
    public let promptTokens: Int
    public let outputTokens: Int
    public let tokensPerSecond: Double
    public let thermalStateBefore: String
    public let thermalStateAfter: String

    public init(
        modelLoadSeconds: TimeInterval,
        wallSeconds: TimeInterval,
        timeToFirstTokenSeconds: TimeInterval,
        promptTokens: Int,
        outputTokens: Int,
        tokensPerSecond: Double,
        thermalStateBefore: String,
        thermalStateAfter: String
    ) {
        self.modelLoadSeconds = modelLoadSeconds
        self.wallSeconds = wallSeconds
        self.timeToFirstTokenSeconds = timeToFirstTokenSeconds
        self.promptTokens = promptTokens
        self.outputTokens = outputTokens
        self.tokensPerSecond = tokensPerSecond
        self.thermalStateBefore = thermalStateBefore
        self.thermalStateAfter = thermalStateAfter
    }
}

public struct TaskExtractionResult: Codable, Sendable {
    public let modelID: String
    public let tasks: [ExtractedTask]
    public let inputText: String
    public let rawOutput: String
    public let metrics: TaskExtractionMetrics

    public init(
        modelID: String,
        tasks: [ExtractedTask],
        inputText: String,
        rawOutput: String,
        metrics: TaskExtractionMetrics
    ) {
        self.modelID = modelID
        self.tasks = tasks
        self.inputText = inputText
        self.rawOutput = rawOutput
        self.metrics = metrics
    }
}

public struct ScreenshotTaskExtractionResult: Codable, Sendable {
    public let ocr: VisionOCRResult
    public let ocrDurationSeconds: TimeInterval
    public let extraction: TaskExtractionResult

    public init(
        ocr: VisionOCRResult,
        ocrDurationSeconds: TimeInterval,
        extraction: TaskExtractionResult
    ) {
        self.ocr = ocr
        self.ocrDurationSeconds = ocrDurationSeconds
        self.extraction = extraction
    }
}

struct TaskEnvelope: Codable, Sendable {
    let tasks: [ExtractedTask]
}

enum TaskOutputParser {
    static func parse(_ text: String) throws -> [ExtractedTask] {
        let withoutThinking = removingThinking(from: text)
        let candidates = [
            withoutThinking.trimmingCharacters(in: .whitespacesAndNewlines),
            firstBalancedJSON(in: withoutThinking)
        ].compactMap { $0 }

        for candidate in candidates {
            let cleaned = candidate
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```JSON", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = cleaned.data(using: .utf8) else { continue }
            if let envelope = try? JSONDecoder().decode(TaskEnvelope.self, from: data) {
                return cleanedTasks(envelope.tasks)
            }
            if let tasks = try? JSONDecoder().decode([ExtractedTask].self, from: data) {
                return cleanedTasks(tasks)
            }
        }
        throw ParseError.invalidJSON
    }

    private static func cleanedTasks(_ tasks: [ExtractedTask]) -> [ExtractedTask] {
        var seen: Set<String> = []
        return tasks.compactMap { task in
            let text = task.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, Int(text) == nil else { return nil }
            let key = text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
            guard seen.insert(key).inserted else { return nil }
            return ExtractedTask(
                text: text,
                requester: task.requester,
                dueDate: task.dueDate,
                assignee: task.assignee,
                evidence: task.evidence
            )
        }
    }

    private static func removingThinking(from text: String) -> String {
        guard let start = text.range(of: "<think>"),
              let end = text.range(of: "</think>", range: start.upperBound..<text.endIndex) else {
            return text
        }
        var result = text
        result.removeSubrange(start.lowerBound..<end.upperBound)
        return result
    }

    private static func firstBalancedJSON(in text: String) -> String? {
        guard let start = text.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        let opening = text[start]
        let closing: Character = opening == "{" ? "}" : "]"
        var depth = 0
        var insideString = false
        var escaped = false

        for index in text.indices[start...] {
            let character = text[index]
            if insideString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { insideString = false }
                continue
            }
            if character == "\"" { insideString = true }
            else if character == opening { depth += 1 }
            else if character == closing {
                depth -= 1
                if depth == 0 { return String(text[start...index]) }
            }
        }
        return nil
    }

    enum ParseError: LocalizedError {
        case invalidJSON
        var errorDescription: String? { "The model did not return the required task JSON." }
    }
}

enum TaskProvenanceEnricher {
    static func enrich(_ tasks: [ExtractedTask], sourceText: String) -> [ExtractedTask] {
        tasks.map { task in
            let dueDate = validatedDueDate(task.dueDate, sourceText: sourceText)
            let supportingEvidence = exactSupportingEvidence(for: task, in: sourceText)
            guard let match = sourceRange(for: task.text, in: sourceText) else {
                return ExtractedTask(
                    text: task.text,
                    requester: task.requester ?? requester(from: task.evidence ?? ""),
                    dueDate: dueDate,
                    assignee: task.assignee,
                    evidence: supportingEvidence ?? task.evidence
                )
            }
            let prefix = String(sourceText[..<match.lowerBound])
            let quote = String(sourceText[match]).trimmingCharacters(in: .whitespacesAndNewlines)
            return ExtractedTask(
                text: task.text,
                requester: task.requester ?? requester(from: prefix),
                dueDate: dueDate,
                assignee: task.assignee,
                evidence: supportingEvidence ?? (quote.isEmpty ? task.evidence : quote)
            )
        }
    }

    private static func exactSupportingEvidence(
        for task: ExtractedTask,
        in sourceText: String
    ) -> String? {
        guard let evidence = task.evidence,
              sourceRange(for: task.text, in: evidence) != nil,
              let match = sourceRange(for: evidence, in: sourceText) else {
            return nil
        }
        let quote = String(sourceText[match]).trimmingCharacters(in: .whitespacesAndNewlines)
        return quote.isEmpty ? nil : quote
    }

    private static func validatedDueDate(_ value: String?, sourceText: String) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let deadlineCue = #"\b(?:by|before|due|deadline|until|no\s+later\s+than)\b"#
        guard sourceText.range(
            of: deadlineCue,
            options: [.regularExpression, .caseInsensitive]
        ) != nil else {
            return nil
        }
        guard cleaned.range(of: #"^(?:19|20)\d{2}$"#, options: .regularExpression) != nil else {
            return cleaned
        }
        let escaped = NSRegularExpression.escapedPattern(for: cleaned)
        let pattern = #"\b(?:by|before|due|deadline|until|no\s+later\s+than)\s+"# + escaped + #"\b"#
        return sourceText.range(of: pattern, options: [.regularExpression, .caseInsensitive]) == nil
            ? nil
            : cleaned
    }

    private static func sourceRange(for task: String, in source: String) -> Range<String.Index>? {
        let words = task.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        let pattern = words
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: #"\s+"#)
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, range: range) else { return nil }
        return Range(match.range, in: source)
    }

    private static func requester(from text: String) -> String? {
        let pattern = #"^\s*(.+?)\s+\d{1,2}:\d{2}\s*(?:AM|PM)\s*$"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .anchorsMatchLines]
        ) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.matches(in: text, range: range).last,
              match.numberOfRanges > 1,
              let nameRange = Range(match.range(at: 1), in: text) else { return nil }
        let name = text[nameRange].trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

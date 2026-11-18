import CoreGraphics
import Foundation
import Testing
@testable import MLXTaskExtractor

@Suite("MLXTaskExtractor")
struct MLXTaskExtractorTests {
    @Test("Normalizes captures for Vision OCR")
    func normalizesOCRImage() throws {
        let gray = try #require(CGColorSpace(name: CGColorSpace.linearGray))
        let context = try #require(CGContext(
            data: nil,
            width: 17,
            height: 11,
            bitsPerComponent: 8,
            bytesPerRow: 17,
            space: gray,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        let source = try #require(context.makeImage())
        let normalized = try VisionOCR.normalizedImage(source)
        #expect(normalized.width == 17)
        #expect(normalized.height == 11)
        #expect(normalized.bitsPerPixel == 32)
        #expect(normalized.colorSpace?.model == .rgb)
    }

    @Test("Repairs OCR spacing inside plus-addressed emails")
    func repairsEmailSpacing() {
        let text = "Use payroll+demo@example. com and billing+cur rency@example. com please"
        #expect(
            VisionOCR.cleanedText(text)
                == "Use payroll+demo@example.com and billing+currency@example.com please"
        )
    }

    @Test("Parses, cleans, and deduplicates task JSON")
    func parsesTasks() throws {
        let output = #"{"tasks":[{"text":"Fix endpoint","dueDate":null},{"text":" Fix   endpoint "},{"text":"8"}]}"#
        let tasks = try TaskOutputParser.parse(output)
        #expect(tasks.map(\.text) == ["Fix endpoint"])
    }

    @Test("Accepts fenced and prose-wrapped JSON")
    func acceptsWrappedJSON() throws {
        let fenced = """
        ```json
        {"tasks":[]}
        ```
        """
        #expect(try TaskOutputParser.parse(fenced).isEmpty)
        let prose = #"Result: {"tasks":[{"text":"Fix exchange endpoint"}]} Done."#
        #expect(try TaskOutputParser.parse(prose).first?.text == "Fix exchange endpoint")
    }

    @Test("Aligns evidence and requester while rejecting a non-deadline year")
    func enrichesProvenance() {
        let source = """
        Monday, October 26th
        Taylor Example 10:38 AM
        Could you process at least one payroll with paystubs? A 2026 pay date would be ideal.
        """
        let task = ExtractedTask(
            text: "process at least one payroll with paystubs?",
            dueDate: "2026",
            evidence: "Taylor Example 10:38 AM"
        )
        let enriched = TaskProvenanceEnricher.enrich([task], sourceText: source)
        #expect(enriched[0].requester == "Taylor Example")
        #expect(enriched[0].dueDate == nil)
        #expect(enriched[0].evidence == "process at least one payroll with paystubs?")
    }

    @Test("Keeps a bare year when explicit deadline language applies")
    func retainsDeadlineYear() {
        let source = "Mina Shah 9:15 AM\nPlease complete the migration by 2026."
        let task = ExtractedTask(text: "complete the migration by 2026.", dueDate: "2026")
        let enriched = TaskProvenanceEnricher.enrich([task], sourceText: source)
        #expect(enriched[0].dueDate == "2026")
    }

    @Test("Rejects a message-header date without deadline language")
    func rejectsHeaderDate() {
        let source = "Tuesday, April 7th\nTaylor Example 10:38 AM\nPlease review the report."
        let task = ExtractedTask(text: "review the report", dueDate: "2030-04-07")
        let enriched = TaskProvenanceEnricher.enrich([task], sourceText: source)
        #expect(enriched[0].dueDate == nil)
    }

    @Test("Keeps exact evidence that adds context to terse task text")
    func retainsSupportingEvidence() {
        let source = "And btw billing+currency@example.com still gets \"This feature is not available\""
        let task = ExtractedTask(
            text: "billing+currency@example.com",
            evidence: "billing+currency@example.com still gets \"This feature is not available\""
        )
        let enriched = TaskProvenanceEnricher.enrich([task], sourceText: source)
        #expect(enriched[0].evidence == task.evidence)
    }

    @Test("Publishes the frozen extraction contract")
    func publicContract() {
        #expect(TaskExtractor.pipelineVersion == 12)
        #expect(TaskExtractor.defaultModelID.contains("Llama-3.2-1B"))
        #expect(TaskExtractor.taskSchema.contains("dueDate"))
    }

    @Test(
        "Extracts twice with one resident model",
        .enabled(if: ProcessInfo.processInfo.environment["MLX_INTEGRATION_TESTS"] == "1")
    )
    func repeatedExtraction() async throws {
        let extractor = TaskExtractor()
        let text = """
        Tuesday, April 7th
        Taylor Example 10:38 AM
        Could you process one completed payroll with paystubs in payroll+demo@example.com?
        What's the full list of possible company entity_type values? We need to map them correctly.
        Also, billing+currency@example.com still gets "This feature is not available".
        Thanks!
        """

        let first = try await extractor.extract(from: text)
        let second = try await extractor.extract(from: text)

        #expect(first.metrics.modelLoadSeconds >= 0)
        #expect(second.metrics.modelLoadSeconds == 0)
        for result in [first, second] {
            #expect(result.tasks.count == 3)
            #expect(result.tasks.contains { $0.text.localizedCaseInsensitiveContains("payroll") })
            #expect(result.tasks.contains { $0.text.localizedCaseInsensitiveContains("entity_type") })
            #expect(result.tasks.contains { task in
                task.text.localizedCaseInsensitiveContains("currency@example.com")
                    && task.evidence?.localizedCaseInsensitiveContains("not available") == true
            })
            #expect(result.tasks.allSatisfy { $0.dueDate == nil })
        }
    }
}

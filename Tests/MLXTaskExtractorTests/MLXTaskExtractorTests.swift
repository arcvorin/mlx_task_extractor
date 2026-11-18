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
        let text = "Use aladcani+codev@every. io and idiscuvich+cur rency@every. io please"
        #expect(
            VisionOCR.cleanedText(text)
                == "Use aladcani+codev@every.io and idiscuvich+currency@every.io please"
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
        Juan Giupponi 10:38 AM
        Could you process at least one payroll with paystubs? A 2026 pay date would be ideal.
        """
        let task = ExtractedTask(
            text: "process at least one payroll with paystubs?",
            dueDate: "2026",
            evidence: "Juan Giupponi 10:38 AM"
        )
        let enriched = TaskProvenanceEnricher.enrich([task], sourceText: source)
        #expect(enriched[0].requester == "Juan Giupponi")
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

    @Test("Publishes the frozen extraction contract")
    func publicContract() {
        #expect(TaskExtractor.pipelineVersion == 11)
        #expect(TaskExtractor.defaultModelID.contains("Llama-3.2-1B"))
        #expect(TaskExtractor.taskSchema.contains("dueDate"))
    }

    @Test(
        "Extracts twice with one resident model",
        .enabled(if: ProcessInfo.processInfo.environment["MLX_INTEGRATION_TESTS"] == "1")
    )
    func repeatedExtraction() async throws {
        let extractor = TaskExtractor()
        let text = "Alex Morgan 9:30 AM\nPlease send the project update by Friday."

        let first = try await extractor.extract(from: text)
        let second = try await extractor.extract(from: text)

        #expect(first.metrics.modelLoadSeconds >= 0)
        #expect(second.metrics.modelLoadSeconds == 0)
        #expect(!first.rawOutput.isEmpty)
        #expect(!second.rawOutput.isEmpty)
    }
}

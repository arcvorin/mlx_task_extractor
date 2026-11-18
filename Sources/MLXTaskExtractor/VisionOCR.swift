import CoreGraphics
import Foundation
@preconcurrency import Vision

public struct VisionOCRResult: Codable, Hashable, Sendable {
    public let text: String
    public let strategy: String
    public let recoveredFrom: String?

    public init(text: String, strategy: String, recoveredFrom: String?) {
        self.text = text
        self.strategy = strategy
        self.recoveredFrom = recoveredFrom
    }
}

public enum VisionOCR {
    public static func recognizeText(in image: CGImage) async throws -> VisionOCRResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let normalized = try normalizedImage(image)
                    let strategies: [(String, VNRequestTextRecognitionLevel, Bool)] = [
                        ("fast", .fast, false),
                        ("accurate with language correction", .accurate, true)
                    ]
                    var failures: [String] = []
                    for strategy in strategies {
                        do {
                            let text = try recognize(
                                normalized,
                                level: strategy.1,
                                usesLanguageCorrection: strategy.2
                            )
                            continuation.resume(returning: VisionOCRResult(
                                text: text,
                                strategy: strategy.0,
                                recoveredFrom: failures.first
                            ))
                            return
                        } catch {
                            failures.append(describe(error))
                        }
                    }
                    throw VisionOCRError.allStrategiesFailed(failures)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public static func normalizedImage(_ image: CGImage) throws -> CGImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw VisionOCRError.couldNotNormalizeImage
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let normalized = context.makeImage() else {
            throw VisionOCRError.couldNotNormalizeImage
        }
        return normalized
    }

    public static func cleanedText(_ text: String) -> String {
        let replacements = [
            (#"(?i)([a-z0-9._%+-]*\+[a-z0-9._%+-]+)\s+([a-z0-9._%+-]+@)"#, "$1$2"),
            (#"(?i)(@[a-z0-9-]+(?:\.[a-z0-9-]+)*)\.\s+([a-z]{2,})\b"#, "$1.$2")
        ]
        return replacements.reduce(text) { output, replacement in
            guard let expression = try? NSRegularExpression(pattern: replacement.0) else {
                return output
            }
            return expression.stringByReplacingMatches(
                in: output,
                range: NSRange(output.startIndex..., in: output),
                withTemplate: replacement.1
            )
        }
    }

    private static func recognize(
        _ image: CGImage,
        level: VNRequestTextRecognitionLevel,
        usesLanguageCorrection: Bool
    ) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = usesLanguageCorrection
        request.revision = VNRecognizeTextRequestRevision3
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        let text = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
        return cleanedText(text)
    }

    private static func describe(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code): \(error.localizedDescription)"
    }
}

public enum VisionOCRError: LocalizedError {
    case couldNotNormalizeImage
    case allStrategiesFailed([String])

    public var errorDescription: String? {
        switch self {
        case .couldNotNormalizeImage:
            "Vision OCR could not create a standard sRGB image from the input."
        case .allStrategiesFailed(let failures):
            "Vision OCR failed in fast and accurate modes. \(failures.joined(separator: " | "))"
        }
    }
}

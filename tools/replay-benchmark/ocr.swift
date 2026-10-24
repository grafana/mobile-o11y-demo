// Local macOS Vision diagnostic. Input/output paths contain only masked synthetic test images.
import Foundation
import Vision

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let paths = try JSONDecoder().decode([String].self, from: Data(contentsOf: input))
struct TextLine: Codable {
    let text: String
    let confidence: Float
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}
var report: [String: [TextLine]] = [:]
for path in paths {
    try autoreleasepool {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(url: URL(fileURLWithPath: path), options: [:]).perform([request])
        report[path] = (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return TextLine(text: text.string, confidence: text.confidence, x: box.minX, y: box.minY,
                            width: box.width, height: box.height)
        }
    }
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(report).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))

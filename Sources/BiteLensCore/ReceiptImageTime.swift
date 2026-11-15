import Foundation
import ImageIO
import Vision

enum ReceiptImageTime {
    static func emailHeader(in data: Data) async -> String? {
        await Task.detached(priority: .userInitiated) { recognizeHeader(in: data) }.value
    }

    private static func recognizeHeader(in data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 2_400,
              ] as CFDictionary) else { return nil }

        let request = VNRecognizeTextRequest()
        do { try VNImageRequestHandler(cgImage: image).perform([request]) }
        catch { return nil }
        let lines = (request.results ?? []).compactMap { observation -> (text: String, box: CGRect)? in
            guard let text = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces)
            else { return nil }
            return (text, observation.boundingBox)
        }

        return emailHeader(from: lines)
    }

    static func emailHeader(from lines: [(text: String, box: CGRect)]) -> String? {
        // In an email header the sender's time can be immediately above the
        // recipient row. Require that relationship and an explicit AM or PM.
        let recipients = lines.filter { $0.text.lowercased().hasPrefix("to ") || $0.text.lowercased().hasPrefix("to:") }
        let times = Set(lines.compactMap { line -> String? in
            guard line.box.midY < 0.93, recipients.contains(where: { recipient in
                let distance = line.box.midY - recipient.box.midY
                return distance > 0 && distance < 0.075 && abs(line.box.minX - recipient.box.minX) < 0.085
            }), let match = line.text.uppercased().wholeMatch(of: /(?:TODAY\s+(?:AT\s+)?)?(\d{1,2}):(\d{2})\s*([AP])\.?M\.?/),
                  let hour = Int(match.1), (1...12).contains(hour),
                  let minute = Int(match.2), minute < 60 else { return nil }
            return String(format: "%02d:%02d", hour % 12 + (match.3 == "P" ? 12 : 0), minute)
        })
        return times.count == 1 ? times.first : nil
    }
}

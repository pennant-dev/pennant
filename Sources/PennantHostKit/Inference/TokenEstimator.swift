import PennantCore
import Foundation
import ImageIO

/// Heuristic token accounting for context budgeting. Not a tokenizer; errs on the high side.
public enum TokenEstimator {
    /// Average characters per token across English prose, code and JSON for recent tokenizers.
    public static let charactersPerToken = 3.6
    /// Vision encoders commonly use 28x28 (or 14x14 merged 2x2) pixel patches per token.
    public static let pixelsPerImageToken = 28 * 28
    public static let maxTokensPerImage = 2000
    public static let unknownImageTokens = 1000
    public static let perMessageOverhead = 4

    public static func tokens(forText text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(1, Int((Double(text.count) / charactersPerToken).rounded(.up)))
    }

    public static func tokens(forImage data: Data) -> Int {
        guard let (width, height) = imageDimensions(data), width > 0, height > 0 else { return unknownImageTokens }
        return min(maxTokensPerImage, max(16, (width * height) / pixelsPerImageToken))
    }

    public static func tokens(forImageWidth width: Int, height: Int) -> Int {
        guard width > 0, height > 0 else { return unknownImageTokens }
        return min(maxTokensPerImage, max(16, (width * height) / pixelsPerImageToken))
    }

    public static func tokens(for tool: ToolSpec) -> Int {
        tokens(forText: tool.name + " " + tool.description + " " + tool.inputSchema.compactText) + 8
    }

    public static func tokens(for message: ModelMessage) -> Int {
        var total = perMessageOverhead
        for part in message.parts {
            switch part {
            case .text(let t): total += tokens(forText: t)
            case .image(let data, _): total += tokens(forImage: data)
            }
        }
        for call in message.toolCalls {
            total += tokens(forText: call.name + call.arguments.compactText) + 6
        }
        if message.toolName != nil { total += 4 }
        return total
    }

    public static func tokens(for messages: [ModelMessage], tools: [ToolSpec]) -> Int {
        messages.reduce(0) { $0 + tokens(for: $1) } + tools.reduce(0) { $0 + tokens(for: $1) } + (tools.isEmpty ? 0 : 12)
    }

    /// Reads pixel dimensions from the image header without decoding the bitmap.
    public static func imageDimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }
}

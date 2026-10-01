import MarkdownUI
import SwiftUI

/// Renders agent Markdown (headings, lists, code blocks, tables, quotes, links) in Pennant's type and colours.
/// `onDark` switches the palette for the black user bubble.
public struct PennantMarkdown: View {
    var text: String
    var onDark: Bool
    /// Body text size at 100%; nil: the size replies use.
    var size: CGFloat?

    public init(_ text: String, onDark: Bool = false, size: CGFloat? = nil) {
        self.text = text
        self.onDark = onDark
        self.size = size
    }

    public var body: some View {
        Markdown(text)
            .markdownTheme(.pennant(onDark ? .onDark : .standard, bodySize: (size ?? bodySize) * PennantZoom.shared.factor))
            .textSelection(.enabled)
    }
}

/// Whether text is written in Markdown: a heading, a fence, a table, a quote or a list of two or more on lines of
/// their own, or bold, inline code or a link inside a line. A post or an email without those reads as plain text.
enum MarkdownDetector {
    private static let blockPatterns = [
        #"^ {0,3}#{1,6} \S"#,                                  // heading
        #"^ {0,3}(```|~~~)"#,                                   // fence
        #"^ {0,3}\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$"#, // table separator row
        #"^ {0,3}> \S"#,                                        // quote
    ].map { try! NSRegularExpression(pattern: $0, options: .anchorsMatchLines) }
    private static let listItem = try! NSRegularExpression(pattern: #"^ {0,3}([-*+]|\d{1,3}[.)]) \S"#, options: .anchorsMatchLines)
    private static let inline = try! NSRegularExpression(pattern: #"\*\*[^*\n]+\*\*|__[^_\n]+__|`[^`\n]+`|\[[^\]\n]+\]\((https?://|mailto:)[^)\s]+\)"#)

    static func looksLikeMarkdown(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        if blockPatterns.contains(where: { $0.firstMatch(in: text, range: range) != nil }) { return true }
        if listItem.numberOfMatches(in: text, range: range) >= 2 { return true }
        return inline.firstMatch(in: text, range: range) != nil
    }
}

/// The colours a Markdown theme needs; everything else is fixed by the design system.
struct MarkdownPalette {
    var ink: Color
    var secondary: Color
    var link: Color
    var codeBackground: Color
    var rule: Color

    @MainActor static let standard = MarkdownPalette(ink: PennantTheme.ink, secondary: PennantTheme.inkSecondary, link: PennantTheme.brandInk, codeBackground: PennantTheme.ink.opacity(0.07), rule: PennantTheme.border)
    @MainActor static let onDark = MarkdownPalette(ink: PennantTheme.userBubbleText, secondary: PennantTheme.userBubbleText.opacity(0.7), link: PennantTheme.userBubbleText, codeBackground: PennantTheme.userBubbleText.opacity(0.14), rule: PennantTheme.userBubbleText.opacity(0.3))
}

/// Body text size at 100%: a touch larger than the system's small UI text so replies read easily.
#if os(iOS)
private let bodySize: CGFloat = 16
#else
private let bodySize: CGFloat = 14
#endif

extension Theme {
    /// Starts from MarkdownUI's basic theme (lists, tables, task markers) and restyles the surfaces and type.
    /// Block styles are wrapper views because SwiftUI modifiers must run on the main actor and the style closures do not.
    static func pennant(_ p: MarkdownPalette, bodySize: CGFloat) -> Theme {
        Theme.basic
            .text {
                ForegroundColor(p.ink)
                FontSize(bodySize)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.86))
                BackgroundColor(p.codeBackground)
            }
            .strong { FontWeight(.semibold) }
            .link { ForegroundColor(p.link) }
            .heading1 { HeadingBlock(label: $0.label, scale: 1.3, top: 16, bottom: 8) }
            .heading2 { HeadingBlock(label: $0.label, scale: 1.18, top: 16, bottom: 6) }
            .heading3 { HeadingBlock(label: $0.label, scale: 1.06, top: 12, bottom: 5) }
            .heading4 { HeadingBlock(label: $0.label, scale: 1.0, top: 8, bottom: 3) }
            .paragraph { ParagraphBlock(label: $0.label) }
            .listItem { ListItemBlock(label: $0.label) }
            .blockquote { QuoteBlock(label: $0.label, palette: p) }
            .codeBlock { CodeBlock(label: $0.label, language: $0.language, palette: p) }
            .tableCell { TableCellBlock(label: $0.label, isHeader: $0.row == 0) }
            .thematicBreak { RuleBlock(palette: p) }
    }
}

private struct HeadingBlock: View {
    var label: BlockConfiguration.Label
    var scale: CGFloat
    var top: CGFloat
    var bottom: CGFloat
    var body: some View {
        label
            .markdownMargin(top: top, bottom: bottom)
            .markdownTextStyle { FontWeight(.semibold); FontSize(.em(scale)) }
    }
}

private struct ParagraphBlock: View {
    var label: BlockConfiguration.Label
    var body: some View {
        label
            .fixedSize(horizontal: false, vertical: true)
            .lineSpacing(4)
            .markdownMargin(top: 0, bottom: 12)
    }
}

private struct ListItemBlock: View {
    var label: BlockConfiguration.Label
    var body: some View { label.lineSpacing(3).markdownMargin(top: 0, bottom: 6) }
}

private struct QuoteBlock: View {
    var label: BlockConfiguration.Label
    var palette: MarkdownPalette
    var body: some View {
        label
            .markdownTextStyle { ForegroundColor(palette.secondary) }
            .padding(.leading, 10)
            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1.5).fill(palette.rule).frame(width: 3) }
            .markdownMargin(top: 0, bottom: 8)
    }
}

private struct CodeBlock: View {
    var label: CodeBlockConfiguration.Label
    var language: String?
    var palette: MarkdownPalette
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.zoomed(.caption2).weight(.medium))
                    .foregroundStyle(palette.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                label
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.85))
                    }
                    .padding(10)
            }
        }
        .background(palette.codeBackground, in: RoundedRectangle(cornerRadius: PennantTheme.radiusSmall, style: .continuous))
        .markdownMargin(top: 0, bottom: 8)
    }
}

private struct TableCellBlock: View {
    var label: TableCellConfiguration.Label
    var isHeader: Bool
    var body: some View {
        label
            .markdownTextStyle {
                if isHeader { FontWeight(.semibold) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
    }
}

private struct RuleBlock: View {
    var palette: MarkdownPalette
    var body: some View {
        Rectangle().fill(palette.rule).frame(height: 1).markdownMargin(top: 8, bottom: 8)
    }
}

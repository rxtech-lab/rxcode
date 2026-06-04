import SwiftUI
import RxCodeCore

// MARK: - Lightweight Markdown Renderer

/// Renders simple markdown content (bullets, ordered lists, paragraphs, headings, inline
/// bold/italic/code). Designed for compact briefings/summaries — not a full markdown engine.
struct BriefingMarkdownView: View {
    let text: String
    var fontSize: CGFloat = 13.5

    private var blocks: [Block] {
        Self.parse(GeneratedTextSanitizer.cleanMarkdownDocument(text))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let content):
                    Text(Self.inline(content))
                        .font(.system(size: headingSize(level), weight: .semibold))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                        .padding(.top, 4)
                        .padding(.bottom, 2)
                case .paragraph(let content):
                    Text(Self.inline(content))
                        .font(.system(size: fontSize))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                case .bullet(let content):
                    bulletRow(marker: "•", content: content)
                case .ordered(let number, let content):
                    bulletRow(marker: "\(number).", content: content, monospaced: true)
                }
            }
        }
    }

    private func bulletRow(marker: String, content: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .font(monospaced
                      ? .system(size: fontSize, weight: .semibold).monospacedDigit()
                      : .system(size: fontSize, weight: .semibold))
                .foregroundStyle(ClaudeTheme.accent)
                .frame(minWidth: 14, alignment: .leading)
            Text(Self.inline(content))
                .font(.system(size: fontSize))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return fontSize + 5
        case 2: return fontSize + 3
        case 3: return fontSize + 2
        default: return fontSize + 1
        }
    }

    // MARK: Parsing

    enum Block {
        case heading(level: Int, content: String)
        case paragraph(String)
        case bullet(String)
        case ordered(number: Int, content: String)
    }

    private static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraphBuffer: [String] = []

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            let joined = paragraphBuffer.joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty {
                blocks.append(.paragraph(joined))
            }
            paragraphBuffer.removeAll()
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                flushParagraph()
                continue
            }

            // Heading: # to ######
            if line.hasPrefix("#") {
                var level = 0
                for ch in line {
                    if ch == "#" { level += 1 } else { break }
                }
                if level >= 1, level <= 6, line.count > level,
                   line[line.index(line.startIndex, offsetBy: level)] == " " {
                    flushParagraph()
                    let content = String(line.dropFirst(level + 1)).trimmingCharacters(in: .whitespaces)
                    blocks.append(.heading(level: level, content: content))
                    continue
                }
            }

            // Unordered bullet
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flushParagraph()
                blocks.append(.bullet(String(line.dropFirst(2))))
                continue
            }

            // Ordered list "1. content"
            if let dotIdx = line.firstIndex(of: "."),
               let number = Int(line[line.startIndex..<dotIdx]),
               line.index(after: dotIdx) < line.endIndex,
               line[line.index(after: dotIdx)] == " " {
                flushParagraph()
                let content = String(line[line.index(dotIdx, offsetBy: 2)...])
                blocks.append(.ordered(number: number, content: content))
                continue
            }

            paragraphBuffer.append(line)
        }

        flushParagraph()
        return blocks
    }

    private static func inline(_ content: String) -> AttributedString {
        if var attr = try? AttributedString(
            markdown: content,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            // Style inline code spans
            for run in attr.runs {
                guard let intent = run.inlinePresentationIntent else { continue }
                if intent.contains(.code) {
                    attr[run.range].font = .system(size: 12.5, design: .monospaced)
                    attr[run.range].foregroundColor = ClaudeTheme.textPrimary
                    attr[run.range].backgroundColor = ClaudeTheme.surfaceTertiary
                }
            }
            return attr
        }
        return AttributedString(content)
    }
}

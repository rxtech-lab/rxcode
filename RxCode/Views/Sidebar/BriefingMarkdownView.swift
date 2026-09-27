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
                case .table(let header, let rows):
                    tableView(header: header, rows: rows)
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

    private func tableView(header: [String], rows: [[String]]) -> some View {
        let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                ForEach(0..<columnCount, id: \.self) { column in
                    tableCell(column < header.count ? header[column] : "", isHeader: true)
                }
            }
            Divider().opacity(0.6)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { column in
                        tableCell(column < row.count ? row[column] : "", isHeader: false)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(ClaudeTheme.surfaceSecondary.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(ClaudeTheme.border.opacity(0.6), lineWidth: 0.5)
        )
    }

    private func tableCell(_ content: String, isHeader: Bool) -> some View {
        Text(Self.inline(content))
            .font(.system(size: fontSize - 0.5, weight: isHeader ? .semibold : .regular))
            .foregroundStyle(isHeader ? ClaudeTheme.textPrimary : ClaudeTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
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
        case table(header: [String], rows: [[String]])
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

        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1

            if line.isEmpty {
                flushParagraph()
                continue
            }

            // Table: a pipe row followed by a `|---|---|` separator row.
            if line.hasPrefix("|"), index < lines.count, isTableSeparator(lines[index]) {
                flushParagraph()
                let header = tableCells(line)
                index += 1
                var rows: [[String]] = []
                while index < lines.count, lines[index].hasPrefix("|") {
                    rows.append(tableCells(lines[index]))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
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

    private static func isTableSeparator(_ line: String) -> Bool {
        guard line.contains("-") else { return false }
        return line.allSatisfy { "|-: ".contains($0) }
    }

    private static func tableCells(_ line: String) -> [String] {
        var body = Substring(line)
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|") { body = body.dropLast() }
        return body.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
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

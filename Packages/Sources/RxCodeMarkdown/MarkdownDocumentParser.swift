import Foundation

struct MarkdownDocument: Equatable {
    var blocks: [MarkdownBlock]
}

enum MarkdownBlock: Equatable {
    case heading(level: Int, inlines: [MarkdownInline], range: Range<Int>)
    case paragraph(inlines: [MarkdownInline], range: Range<Int>)
    case list(ordered: Bool, items: [MarkdownListItem], range: Range<Int>)
    case quote(inlines: [MarkdownInline], range: Range<Int>)
    case codeBlock(language: String?, content: String, range: Range<Int>)
    case image(alt: String, source: String, range: Range<Int>)
    case table(headers: [String], rows: [[String]], range: Range<Int>)
    case divider(range: Range<Int>)
}

struct MarkdownListItem: Equatable {
    var number: Int?
    var inlines: [MarkdownInline]
    var range: Range<Int>
}

enum MarkdownInline: Equatable {
    case text(String, range: Range<Int>)
    case strong(String, range: Range<Int>)
    case emphasis(String, range: Range<Int>)
    case code(String, range: Range<Int>)
    case link(label: String, destination: String, range: Range<Int>)
    case image(alt: String, source: String, range: Range<Int>)
}

enum MarkdownDocumentParser {
    static func parse(_ text: String) -> MarkdownDocument {
        let lines = sourceLines(in: text)
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if let fence = fenceInfo(trimmed) {
                let parsed = parseCodeBlock(from: index, fence: fence, lines: lines)
                blocks.append(parsed.block)
                index = parsed.nextIndex
                continue
            }

            if let image = blockImage(trimmed, range: line.startOffset..<line.endOffset) {
                blocks.append(image)
                index += 1
                continue
            }

            if let heading = headingBlock(line) {
                blocks.append(heading)
                index += 1
                continue
            }

            if isDivider(trimmed) {
                blocks.append(.divider(range: line.startOffset..<line.endOffset))
                index += 1
                continue
            }

            if isTableStart(at: index, lines: lines) {
                let parsed = parseTable(from: index, lines: lines)
                blocks.append(parsed.block)
                index = parsed.nextIndex
                continue
            }

            if listMarker(line.text) != nil {
                let parsed = parseList(from: index, lines: lines)
                blocks.append(parsed.block)
                index = parsed.nextIndex
                continue
            }

            if trimmed.hasPrefix(">") {
                let parsed = parseQuote(from: index, lines: lines)
                blocks.append(parsed.block)
                index = parsed.nextIndex
                continue
            }

            let parsed = parseParagraph(from: index, lines: lines)
            blocks.append(parsed.block)
            index = parsed.nextIndex
        }

        return MarkdownDocument(blocks: blocks)
    }

    static func parseInlines(_ text: String, baseOffset: Int = 0) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        var index = text.startIndex

        func offset(_ position: String.Index) -> Int {
            baseOffset + text.distance(from: text.startIndex, to: position)
        }

        func appendText(from start: String.Index, to end: String.Index) {
            guard start < end else { return }
            result.append(.text(String(text[start..<end]), range: offset(start)..<offset(end)))
        }

        while index < text.endIndex {
            if text[index] == "`", let end = text[index...].dropFirst().firstIndex(of: "`") {
                let contentStart = text.index(after: index)
                let content = String(text[contentStart..<end])
                result.append(.code(content, range: offset(index)..<offset(text.index(after: end))))
                index = text.index(after: end)
                continue
            }

            if hasPrefix("**", in: text, at: index),
               let end = rangeOf("**", in: text, after: text.index(index, offsetBy: 2)) {
                let contentStart = text.index(index, offsetBy: 2)
                result.append(.strong(String(text[contentStart..<end]), range: offset(index)..<offset(text.index(end, offsetBy: 2))))
                index = text.index(end, offsetBy: 2)
                continue
            }

            if text[index] == "*",
               let end = text[index...].dropFirst().firstIndex(of: "*") {
                let contentStart = text.index(after: index)
                result.append(.emphasis(String(text[contentStart..<end]), range: offset(index)..<offset(text.index(after: end))))
                index = text.index(after: end)
                continue
            }

            if hasPrefix("![", in: text, at: index),
               let parsed = parseLinkLikeInline(text, at: index, baseOffset: baseOffset, isImage: true) {
                result.append(.image(alt: parsed.label, source: parsed.destination, range: parsed.range))
                index = parsed.endIndex
                continue
            }

            if text[index] == "[",
               let parsed = parseLinkLikeInline(text, at: index, baseOffset: baseOffset, isImage: false) {
                result.append(.link(label: parsed.label, destination: parsed.destination, range: parsed.range))
                index = parsed.endIndex
                continue
            }

            if let parsed = parseAutolink(text, at: index, baseOffset: baseOffset) {
                result.append(.link(label: parsed.destination, destination: parsed.destination, range: parsed.range))
                index = parsed.endIndex
                continue
            }

            let start = index
            repeat {
                index = text.index(after: index)
            } while index < text.endIndex
                && text[index] != "`"
                && text[index] != "*"
                && text[index] != "["
                && !hasPrefix("![", in: text, at: index)
                && parseAutolink(text, at: index, baseOffset: baseOffset) == nil
            appendText(from: start, to: index)
        }

        return result
    }

    static func resolvedURL(for source: String, baseURL: URL?) -> URL? {
        let cleaned = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        if let url = URL(string: cleaned), url.scheme != nil {
            return url
        }
        if let baseURL {
            return URL(string: cleaned, relativeTo: baseURL)?.absoluteURL
        }
        return URL(fileURLWithPath: cleaned)
    }
}

private struct MarkdownSourceLine {
    var text: String
    var startOffset: Int
    var endOffset: Int
}

private struct MarkdownFence {
    var marker: String
    var language: String?
}

private struct ParsedInlineLink {
    var label: String
    var destination: String
    var range: Range<Int>
    var endIndex: String.Index
}

private extension MarkdownDocumentParser {
    static func sourceLines(in text: String) -> [MarkdownSourceLine] {
        var lines: [MarkdownSourceLine] = []
        var offset = 0
        for component in text.components(separatedBy: "\n") {
            let endOffset = offset + component.count
            lines.append(MarkdownSourceLine(text: component, startOffset: offset, endOffset: endOffset))
            offset = endOffset + 1
        }
        return lines
    }

    static func headingBlock(_ line: MarkdownSourceLine) -> MarkdownBlock? {
        let trimmedLeading = line.text.trimmingCharacters(in: .whitespaces)
        var level = 0
        for character in trimmedLeading {
            guard character == "#" else { break }
            level += 1
        }
        guard (1...6).contains(level),
              trimmedLeading.count > level,
              trimmedLeading[trimmedLeading.index(trimmedLeading.startIndex, offsetBy: level)] == " " else {
            return nil
        }
        let content = String(trimmedLeading.dropFirst(level + 1)).trimmingCharacters(in: .whitespaces)
        let leadingWhitespace = line.text.count - line.text.trimmingCharacters(in: .whitespaces).count
        let contentOffset = line.startOffset + leadingWhitespace + level + 1
        return .heading(
            level: level,
            inlines: parseInlines(content, baseOffset: contentOffset),
            range: line.startOffset..<line.endOffset
        )
    }

    static func parseParagraph(from start: Int, lines: [MarkdownSourceLine]) -> (block: MarkdownBlock, nextIndex: Int) {
        var index = start
        var paragraphLines: [MarkdownSourceLine] = []

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  fenceInfo(trimmed) == nil,
                  blockImage(trimmed, range: line.startOffset..<line.endOffset) == nil,
                  headingBlock(line) == nil,
                  !isDivider(trimmed),
                  !isTableStart(at: index, lines: lines),
                  listMarker(line.text) == nil,
                  !trimmed.hasPrefix(">") else {
                break
            }
            paragraphLines.append(line)
            index += 1
        }

        let text = paragraphLines.map(\.text).joined(separator: " ")
        let startOffset = paragraphLines.first?.startOffset ?? lines[start].startOffset
        let endOffset = paragraphLines.last?.endOffset ?? lines[start].endOffset
        return (
            .paragraph(inlines: parseInlines(text, baseOffset: startOffset), range: startOffset..<endOffset),
            index
        )
    }

    static func parseQuote(from start: Int, lines: [MarkdownSourceLine]) -> (block: MarkdownBlock, nextIndex: Int) {
        var index = start
        var quoteParts: [String] = []
        let startOffset = lines[start].startOffset
        var endOffset = lines[start].endOffset

        while index < lines.count {
            let trimmed = lines[index].text.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else { break }
            var content = String(trimmed.dropFirst())
            if content.hasPrefix(" ") {
                content.removeFirst()
            }
            quoteParts.append(content)
            endOffset = lines[index].endOffset
            index += 1
        }

        let text = quoteParts.joined(separator: "\n")
        return (.quote(inlines: parseInlines(text, baseOffset: startOffset), range: startOffset..<endOffset), index)
    }

    static func parseList(from start: Int, lines: [MarkdownSourceLine]) -> (block: MarkdownBlock, nextIndex: Int) {
        let firstMarker = listMarker(lines[start].text)
        let ordered = firstMarker?.number != nil
        var items: [MarkdownListItem] = []
        var index = start
        var endOffset = lines[start].endOffset

        while index < lines.count {
            guard let marker = listMarker(lines[index].text),
                  (marker.number != nil) == ordered else { break }
            let content = String(lines[index].text[marker.contentStart...])
            let baseOffset = lines[index].startOffset + lines[index].text.distance(from: lines[index].text.startIndex, to: marker.contentStart)
            items.append(MarkdownListItem(
                number: marker.number,
                inlines: parseInlines(content, baseOffset: baseOffset),
                range: lines[index].startOffset..<lines[index].endOffset
            ))
            endOffset = lines[index].endOffset
            index += 1
        }

        return (.list(ordered: ordered, items: items, range: lines[start].startOffset..<endOffset), index)
    }

    static func parseCodeBlock(from start: Int, fence: MarkdownFence, lines: [MarkdownSourceLine]) -> (block: MarkdownBlock, nextIndex: Int) {
        var index = start + 1
        var contentLines: [String] = []
        var endOffset = lines[start].endOffset

        while index < lines.count {
            let trimmed = lines[index].text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(fence.marker) {
                endOffset = lines[index].endOffset
                index += 1
                break
            }
            contentLines.append(lines[index].text)
            endOffset = lines[index].endOffset
            index += 1
        }

        return (
            .codeBlock(language: fence.language, content: contentLines.joined(separator: "\n"), range: lines[start].startOffset..<endOffset),
            index
        )
    }

    static func parseTable(from start: Int, lines: [MarkdownSourceLine]) -> (block: MarkdownBlock, nextIndex: Int) {
        var index = start + 2
        var rows: [[String]] = []
        let headers = tableCells(lines[start].text)
        var endOffset = lines[start + 1].endOffset

        while index < lines.count {
            let trimmed = lines[index].text.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("|"), !trimmed.isEmpty else { break }
            rows.append(tableCells(lines[index].text))
            endOffset = lines[index].endOffset
            index += 1
        }

        return (.table(headers: headers, rows: rows, range: lines[start].startOffset..<endOffset), index)
    }

    static func blockImage(_ trimmed: String, range: Range<Int>) -> MarkdownBlock? {
        if let parsed = parseMarkdownImage(trimmed, range: range) {
            return .image(alt: parsed.alt, source: parsed.source, range: range)
        }
        if let parsed = parseHTMLImage(trimmed) {
            return .image(alt: parsed.alt, source: parsed.source, range: range)
        }
        return nil
    }

    static func parseMarkdownImage(_ text: String, range: Range<Int>) -> (alt: String, source: String)? {
        guard text.hasPrefix("!["),
              let closeBracket = text.firstIndex(of: "]"),
              closeBracket < text.index(before: text.endIndex),
              text[text.index(after: closeBracket)] == "(",
              text.hasSuffix(")") else {
            return nil
        }
        let alt = String(text[text.index(text.startIndex, offsetBy: 2)..<closeBracket])
        let sourceStart = text.index(closeBracket, offsetBy: 2)
        let source = String(text[sourceStart..<text.index(before: text.endIndex)])
        return (alt, source)
    }

    static func parseHTMLImage(_ text: String) -> (alt: String, source: String)? {
        guard text.localizedCaseInsensitiveContains("<img"),
              let src = htmlAttribute("src", in: text) else {
            return nil
        }
        return (htmlAttribute("alt", in: text) ?? "", src)
    }

    static func htmlAttribute(_ name: String, in text: String) -> String? {
        let pattern = "\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        for index in 1..<match.numberOfRanges {
            if let range = Range(match.range(at: index), in: text) {
                return String(text[range])
            }
        }
        return nil
    }

    static func isDivider(_ text: String) -> Bool {
        let characters = text.filter { !$0.isWhitespace }
        guard characters.count >= 3,
              let first = characters.first,
              first == "-" || first == "*" || first == "_" else {
            return false
        }
        return characters.allSatisfy { $0 == first }
    }

    static func fenceInfo(_ text: String) -> MarkdownFence? {
        if text.hasPrefix("```") {
            return MarkdownFence(marker: "```", language: fenceLanguage(text.dropFirst(3)))
        }
        if text.hasPrefix("~~~") {
            return MarkdownFence(marker: "~~~", language: fenceLanguage(text.dropFirst(3)))
        }
        return nil
    }

    static func fenceLanguage<S: StringProtocol>(_ text: S) -> String? {
        let language = String(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return language.isEmpty ? nil : language
    }

    static func listMarker(_ text: String) -> (number: Int?, contentStart: String.Index)? {
        let trimmedStart = text.firstIndex { !$0.isWhitespace } ?? text.startIndex
        guard trimmedStart < text.endIndex else { return nil }

        let marker = text[trimmedStart]
        if marker == "-" || marker == "*" || marker == "+",
           text.index(after: trimmedStart) < text.endIndex,
           text[text.index(after: trimmedStart)] == " " {
            return (nil, text.index(trimmedStart, offsetBy: 2))
        }

        var digitEnd = trimmedStart
        while digitEnd < text.endIndex, text[digitEnd].isNumber {
            digitEnd = text.index(after: digitEnd)
        }
        guard digitEnd > trimmedStart,
              digitEnd < text.endIndex,
              text[digitEnd] == ".",
              text.index(after: digitEnd) < text.endIndex,
              text[text.index(after: digitEnd)] == " ",
              let number = Int(text[trimmedStart..<digitEnd]) else {
            return nil
        }
        return (number, text.index(digitEnd, offsetBy: 2))
    }

    static func isTableStart(at index: Int, lines: [MarkdownSourceLine]) -> Bool {
        guard index + 1 < lines.count,
              lines[index].text.contains("|") else {
            return false
        }
        return isTableSeparator(lines[index + 1].text)
    }

    static func isTableSeparator(_ text: String) -> Bool {
        let cells = tableCells(text)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let compact = cell.filter { !$0.isWhitespace }
            return compact.count >= 3
                && compact.allSatisfy { $0 == "-" || $0 == ":" }
                && compact.contains("-")
        }
    }

    static func tableCells(_ text: String) -> [String] {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func hasPrefix(_ prefix: String, in text: String, at index: String.Index) -> Bool {
        text[index...].hasPrefix(prefix)
    }

    static func rangeOf(_ needle: String, in text: String, after index: String.Index) -> String.Index? {
        text[index...].range(of: needle)?.lowerBound
    }

    static func parseLinkLikeInline(_ text: String, at index: String.Index, baseOffset: Int, isImage: Bool) -> ParsedInlineLink? {
        let labelStart = isImage ? text.index(index, offsetBy: 2) : text.index(after: index)
        guard labelStart < text.endIndex,
              let closeBracket = text[labelStart...].firstIndex(of: "]"),
              closeBracket < text.index(before: text.endIndex),
              text[text.index(after: closeBracket)] == "(",
              let closeParen = text[text.index(closeBracket, offsetBy: 2)...].firstIndex(of: ")") else {
            return nil
        }
        let destinationStart = text.index(closeBracket, offsetBy: 2)
        let end = text.index(after: closeParen)
        let startOffset = baseOffset + text.distance(from: text.startIndex, to: index)
        let endOffset = baseOffset + text.distance(from: text.startIndex, to: end)
        return ParsedInlineLink(
            label: String(text[labelStart..<closeBracket]),
            destination: String(text[destinationStart..<closeParen]).replacingOccurrences(of: "`", with: ""),
            range: startOffset..<endOffset,
            endIndex: end
        )
    }

    static func parseAutolink(_ text: String, at index: String.Index, baseOffset: Int) -> ParsedInlineLink? {
        guard text[index...].hasPrefix("http://") || text[index...].hasPrefix("https://") else {
            return nil
        }
        var end = index
        while end < text.endIndex {
            let character = text[end]
            if character.isWhitespace || "])<`".contains(character) {
                break
            }
            end = text.index(after: end)
        }
        while end > index {
            let previous = text.index(before: end)
            if ".,;:!?".contains(text[previous]) {
                end = previous
            } else {
                break
            }
        }
        guard end > index else { return nil }
        let startOffset = baseOffset + text.distance(from: text.startIndex, to: index)
        let endOffset = baseOffset + text.distance(from: text.startIndex, to: end)
        let destination = String(text[index..<end])
        return ParsedInlineLink(label: destination, destination: destination, range: startOffset..<endOffset, endIndex: end)
    }
}

import Foundation

/// Source remains authoritative. Parsing changes presentation only, never storage.
struct MarkdownDocument: Equatable {
    let source: String
    let blocks: [MarkdownBlock]

    init(source: String) {
        self.source = source
        blocks = MarkdownParser(source: source).parse()
    }
}

struct MarkdownSourceSpan: Equatable {
    let startLine: Int
    let endLine: Int
    let startUTF16: Int
    let endUTF16: Int
}

struct MarkdownBlock: Identifiable, Equatable {
    let id: String
    let span: MarkdownSourceSpan
    let kind: MarkdownBlockKind
}

indirect enum MarkdownBlockKind: Equatable {
    case heading(Int, MarkdownInline)
    case paragraph(MarkdownInline)
    case blank(Int)
    case list([MarkdownListItem])
    case quote([MarkdownBlock])
    case code(MarkdownCode)
    case divider
    case table(MarkdownTable)
}

struct MarkdownInline: Equatable {
    let source: String
    let attributed: AttributedString

    init(source: String) {
        self.source = source
        var value = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        // Text never fetches images. Links open only by explicit user action, and
        // custom/file/javascript schemes are not made interactive.
        let unsafeLinks = value.runs.filter { run in
            guard let url = run.link else { return false }
            return !["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "")
        }.map(\.range)
        for range in unsafeLinks { value[range].link = nil }
        attributed = value
    }

    static func paragraph(_ lines: [String]) -> MarkdownInline {
        var text = ""
        for (index, original) in lines.enumerated() {
            var line = original
            let hardSpace = line.hasSuffix("  ")
            let slashCount = line.reversed().prefix { $0 == "\\" }.count
            let hardSlash = slashCount % 2 == 1
            if hardSpace { line = String(line.dropLast(2)) }
            else if hardSlash { line = String(line.dropLast()) }
            text += line
            if index < lines.count - 1 { text += hardSpace || hardSlash ? "\n" : " " }
        }
        return MarkdownInline(source: text)
    }
}

struct MarkdownCode: Equatable {
    let text: String
    let language: String
    let closed: Bool
}

struct MarkdownListItem: Identifiable, Equatable {
    let id: String
    let span: MarkdownSourceSpan
    let text: MarkdownInline
    let ordinal: Int?
    let checked: Bool?
    let indentation: Int
}

enum MarkdownColumnAlignment: Equatable { case leading, center, trailing }
struct MarkdownTableCell: Identifiable, Equatable {
    let id: String
    let column: Int
    let text: MarkdownInline
}
struct MarkdownTableRow: Identifiable, Equatable {
    let id: String
    let cells: [MarkdownTableCell]
}
struct MarkdownTable: Equatable {
    let header: MarkdownTableRow
    let alignments: [MarkdownColumnAlignment]
    let rows: [MarkdownTableRow]
}

/// View-owned state keyed by meeting identity, shared directly with behavior tests.
struct MarkdownNoteSession: Equatable {
    enum Mode: Equatable { case preview, editing }
    struct SaveTicket: Equatable {
        let meetingID: String
        let generation: UInt64
        let draft: String
    }
    let meetingID: String
    private(set) var mode: Mode = .preview
    private(set) var pendingPreview: SaveTicket?
    var saving: Bool { pendingPreview != nil }
    private var generation: UInt64 = 0

    init(meetingID: String) { self.meetingID = meetingID }
    mutating func beginEditing() {
        // Resuming input invalidates an older request to switch to preview.
        generation &+= 1; pendingPreview = nil; mode = .editing
    }
    mutating func beginSaving(draft: String, currentMeetingID: String?, switching: Bool) -> SaveTicket? {
        guard mode == .editing, !saving, !switching, currentMeetingID == meetingID else { return nil }
        generation &+= 1
        let ticket = SaveTicket(meetingID: meetingID, generation: generation, draft: draft)
        pendingPreview = ticket
        return ticket
    }
    @discardableResult
    mutating func finishSaving(_ ticket: SaveTicket, succeeded: Bool, currentMeetingID: String?, currentDraft: String, dirty: Bool, switching: Bool) -> Bool {
        guard ticket.meetingID == meetingID, ticket.generation == generation, pendingPreview == ticket else { return false }
        pendingPreview = nil
        guard succeeded, !switching, currentMeetingID == meetingID, currentDraft == ticket.draft, !dirty else {
            mode = .editing; return false
        }
        mode = .preview; return true
    }
}

private struct MarkdownLine {
    let text: String
    let raw: String
    let number: Int
    let startUTF16: Int
    var blank: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }
}

private enum MarkdownRules {
    static let heading = try! NSRegularExpression(pattern: #"^ {0,3}(#{1,6})(?:[ \t]+|$)(.*)$"#)
    static let fence = try! NSRegularExpression(pattern: #"^ {0,3}(`{3,}|~{3,})(.*)$"#)
    static let quote = try! NSRegularExpression(pattern: #"^ {0,3}>[ \t]?(.*)$"#)
    static let list = try! NSRegularExpression(pattern: #"^( {0,24})(?:([-+*])|([0-9]{1,9})[.)])[ \t]+(.*)$"#)
    static let task = try! NSRegularExpression(pattern: #"^\[([ xX])\](?:[ \t]+|$)(.*)$"#)
    static let delimiter = try! NSRegularExpression(pattern: #"^:?-{3,}:?$"#)
    static let closingHeading = try! NSRegularExpression(pattern: #"[ \t]+#+[ \t]*$"#)
    static func captures(_ regex: NSRegularExpression, _ text: String) -> [String?]? {
        let raw = text as NSString
        guard let result = regex.firstMatch(in: text, range: NSRange(location: 0, length: raw.length)) else { return nil }
        return (1..<result.numberOfRanges).map { index in
            let range = result.range(at: index)
            return range.location == NSNotFound ? nil : raw.substring(with: range)
        }
    }
}

private struct MarkdownParser {
    let source: String
    let lines: [MarkdownLine]
    let quoteDepth: Int

    init(source: String, quoteDepth: Int = 0) {
        self.source = source
        self.quoteDepth = quoteDepth
        guard !source.isEmpty else { lines = []; return }
        var result: [MarkdownLine] = [], offset = 0
        let pieces = source.components(separatedBy: "\n")
        for (index, piece) in pieces.enumerated() {
            if index == pieces.count - 1 && piece.isEmpty && source.hasSuffix("\n") { break }
            let raw = piece + (index < pieces.count - 1 ? "\n" : "")
            let text = piece.hasSuffix("\r") ? String(piece.dropLast()) : piece
            result.append(MarkdownLine(text: text, raw: raw, number: index, startUTF16: offset))
            offset += raw.utf16.count
        }
        lines = result
    }

    private func span(_ start: Int, _ end: Int) -> MarkdownSourceSpan {
        let last = lines[end - 1]
        return MarkdownSourceSpan(startLine: lines[start].number, endLine: last.number + 1, startUTF16: lines[start].startUTF16, endUTF16: last.startUTF16 + last.raw.utf16.count)
    }
    private func block(_ kind: MarkdownBlockKind, _ tag: String, _ start: Int, _ end: Int) -> MarkdownBlock {
        let location = span(start, end)
        return MarkdownBlock(id: "\(tag):\(location.startUTF16)", span: location, kind: kind)
    }
    private func rawText(_ start: Int, _ end: Int) -> String { lines[start..<end].map(\.raw).joined() }
    private func fence(_ text: String) -> (marker: Character, count: Int, language: String)? {
        guard let values = MarkdownRules.captures(MarkdownRules.fence, text), let token = values[0], let marker = token.first else { return nil }
        let info = (values[1] ?? "").trimmingCharacters(in: .whitespaces)
        if marker == "`" && info.contains("`") { return nil }
        return (marker, token.count, info.components(separatedBy: .whitespaces).first ?? "")
    }
    private func heading(_ text: String) -> (Int, String)? {
        guard let values = MarkdownRules.captures(MarkdownRules.heading, text), let prefix = values[0] else { return nil }
        let body = values[1] ?? ""
        let stripped = MarkdownRules.closingHeading.stringByReplacingMatches(in: body, range: NSRange(location: 0, length: (body as NSString).length), withTemplate: "")
        return (prefix.count, stripped)
    }
    private func divider(_ text: String) -> Bool {
        guard text.prefix(while: { $0 == " " }).count <= 3 else { return false }
        let compact = text.filter { $0 != " " && $0 != "\t" }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }
    private func quote(_ text: String) -> String? { MarkdownRules.captures(MarkdownRules.quote, text)?[0] ?? nil }
    private func list(_ text: String) -> (body: String, ordinal: Int?, checked: Bool?, indentation: Int)? {
        guard let values = MarkdownRules.captures(MarkdownRules.list, text) else { return nil }
        var body = values[3] ?? "", checked: Bool?
        if let task = MarkdownRules.captures(MarkdownRules.task, body) {
            checked = (task[0] ?? "").lowercased() == "x"; body = task[1] ?? ""
        }
        return (body, values[2].flatMap(Int.init), checked, (values[0] ?? "").count)
    }
    private func startsBlock(_ index: Int) -> Bool {
        let text = lines[index].text
        return heading(text) != nil || fence(text) != nil || divider(text) || quote(text) != nil || list(text) != nil || tableHeader(index) != nil
    }

    private struct Cell { let raw: String; let offset: Int }
    private func cells(_ text: String) -> (values: [Cell], hasPipe: Bool) {
        var values: [Cell] = [], current = "", offset = 0, start = 0, codeTicks = 0, hasPipe = false
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let char = text[cursor]
            if char == "\\" {
                current.append(char); offset += 1; cursor = text.index(after: cursor)
                if cursor < text.endIndex {
                    let next = text[cursor]; current.append(next); offset += String(next).utf16.count; cursor = text.index(after: cursor)
                }
                continue
            }
            if char == "`" {
                var count = 0
                while cursor < text.endIndex && text[cursor] == "`" { current.append("`"); count += 1; offset += 1; cursor = text.index(after: cursor) }
                if codeTicks == 0 { codeTicks = count } else if count == codeTicks { codeTicks = 0 }
                continue
            }
            if char == "|" && codeTicks == 0 {
                values.append(Cell(raw: current.trimmingCharacters(in: .whitespaces), offset: start))
                current = ""; hasPipe = true; start = offset + 1
            } else { current.append(char) }
            offset += String(char).utf16.count; cursor = text.index(after: cursor)
        }
        values.append(Cell(raw: current.trimmingCharacters(in: .whitespaces), offset: start))
        if values.first?.raw.isEmpty == true && text.trimmingCharacters(in: .whitespaces).hasPrefix("|") { values.removeFirst() }
        if values.last?.raw.isEmpty == true && text.trimmingCharacters(in: .whitespaces).hasSuffix("|") { values.removeLast() }
        return (values, hasPipe)
    }
    private func tableHeader(_ index: Int) -> [MarkdownColumnAlignment]? {
        guard index + 1 < lines.count else { return nil }
        let header = cells(lines[index].text), delimiter = cells(lines[index + 1].text)
        guard header.hasPipe, !header.values.isEmpty, header.values.count == delimiter.values.count else { return nil }
        var alignments: [MarkdownColumnAlignment] = []
        for cell in delimiter.values {
            guard MarkdownRules.delimiter.firstMatch(in: cell.raw, range: NSRange(location: 0, length: (cell.raw as NSString).length)) != nil else { return nil }
            alignments.append(cell.raw.hasPrefix(":") && cell.raw.hasSuffix(":") ? .center : cell.raw.hasSuffix(":") ? .trailing : .leading)
        }
        return alignments
    }
    private func tableRow(_ index: Int) -> MarkdownTableRow {
        let line = lines[index]
        let columns = cells(line.text).values.enumerated().map { column, cell in
            MarkdownTableCell(id: "cell:\(line.startUTF16 + cell.offset)", column: column, text: MarkdownInline(source: cell.raw))
        }
        return MarkdownTableRow(id: "row:\(line.startUTF16)", cells: columns)
    }

    func parse() -> [MarkdownBlock] {
        var output: [MarkdownBlock] = [], index = 0
        while index < lines.count {
            let start = index, line = lines[index]
            if line.blank {
                while index < lines.count && lines[index].blank { index += 1 }
                output.append(block(.blank(index - start), "blank", start, index)); continue
            }
            if let opening = fence(line.text) {
                index += 1
                let bodyStart = index
                var closed = false
                while index < lines.count {
                    let indent = lines[index].text.prefix { $0 == " " }.count
                    let candidate = String(lines[index].text.dropFirst(indent))
                    let markerCount = candidate.prefix { $0 == opening.marker }.count
                    if indent <= 3, markerCount >= opening.count, candidate.dropFirst(markerCount).trimmingCharacters(in: .whitespaces).isEmpty { closed = true; break }
                    index += 1
                }
                let code = MarkdownCode(text: rawText(bodyStart, index), language: opening.language, closed: closed)
                if closed { index += 1 }
                output.append(block(.code(code), "code", start, index)); continue
            }
            if let value = heading(line.text) {
                index += 1; output.append(block(.heading(value.0, MarkdownInline(source: value.1)), "heading", start, index)); continue
            }
            if let alignments = tableHeader(index) {
                let header = tableRow(index); index += 2
                var rows: [MarkdownTableRow] = []
                while index < lines.count, !lines[index].blank {
                    let text = lines[index].text
                    if heading(text) != nil || fence(text) != nil || quote(text) != nil || list(text) != nil || divider(text) { break }
                    let row = cells(text)
                    guard row.hasPipe, row.values.count == header.cells.count else { break }
                    rows.append(tableRow(index)); index += 1
                }
                output.append(block(.table(MarkdownTable(header: header, alignments: alignments, rows: rows)), "table", start, index)); continue
            }
            if divider(line.text) { index += 1; output.append(block(.divider, "divider", start, index)); continue }
            if quote(line.text) != nil {
                var content: [String] = []
                while index < lines.count, let text = quote(lines[index].text) { content.append(text); index += 1 }
                let inner = content.joined(separator: "\n")
                // Bound pathological nesting; deeper markers remain readable text.
                let children = quoteDepth < 12 ? MarkdownParser(source: inner, quoteDepth: quoteDepth + 1).parse() : [block(.paragraph(MarkdownInline(source: inner)), "quote-text", start, index)]
                output.append(block(.quote(children), "quote", start, index)); continue
            }
            if list(line.text) != nil {
                var items: [MarkdownListItem] = []
                while index < lines.count, let item = list(lines[index].text) {
                    let itemStart = index; index += 1
                    var content = [item.body]
                    while index < lines.count, !lines[index].blank, list(lines[index].text) == nil {
                        let next = lines[index].text
                        let indentation = next.prefix { $0 == " " }.count
                        guard indentation >= item.indentation + 2, heading(next) == nil, fence(next) == nil, quote(next) == nil else { break }
                        content.append(String(next.dropFirst(item.indentation + 2))); index += 1
                    }
                    let location = span(itemStart, index)
                    items.append(MarkdownListItem(id: "item:\(location.startUTF16)", span: location, text: .paragraph(content), ordinal: item.ordinal, checked: item.checked, indentation: item.indentation))
                }
                output.append(block(.list(items), "list", start, index)); continue
            }
            index += 1
            while index < lines.count, !lines[index].blank, !startsBlock(index) { index += 1 }
            output.append(block(.paragraph(.paragraph(lines[start..<index].map(\.text))), "paragraph", start, index))
        }
        return output
    }
}

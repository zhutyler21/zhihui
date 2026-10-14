import SwiftUI
import AppKit

/// Native block Markdown used by notes, summaries and answers. The cache is
/// derived presentation state; parsing runs only when the input String changes.
struct MarkdownBody: View {
    let text: String
    @State private var document = MarkdownDocument(source: "")

    var body: some View {
        MarkdownBlocks(blocks: document.blocks)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tint(Design.accent)
            .onChange(of: text, initial: true) { _, source in
                document = MarkdownDocument(source: source)
            }
    }
}

private struct MarkdownBlocks: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach(blocks) { block in
                MarkdownBlockRow(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlockRow: View {
    let block: MarkdownBlock

    var body: some View {
        Group {
            switch block.kind {
            case .heading(let level, let text):
                Text(text.attributed)
                    .textSelection(.enabled)
                    .font(headingFont(level))
                    .foregroundStyle(Design.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, level < 3 ? 14 : 7)
                    .accessibilityAddTraits(.isHeader)
            case .paragraph(let text):
                MarkdownInlineText(text: text)
            case .blank(let count):
                Color.clear.frame(height: CGFloat(min(count, 5)) * 3)
                    .accessibilityHidden(true)
            case .list(let items):
                MarkdownList(items: items)
            case .quote(let blocks):
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 2).fill(Design.line)
                        .frame(width: 3)
                        .accessibilityHidden(true)
                    MarkdownBlocks(blocks: blocks)
                }
                .padding(.vertical, 5)
            case .code(let code):
                MarkdownCodeView(code: code)
            case .divider:
                Divider().padding(.vertical, 7).accessibilityHidden(true)
            case .table(let table):
                MarkdownTableView(table: table)
            }
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return Design.Typography.title
        case 2: return Design.Typography.title2
        case 3: return Design.Typography.title3
        case 4: return Design.Typography.headline
        case 5: return Design.Typography.body.weight(.semibold)
        default: return Design.Typography.callout.weight(.semibold)
        }
    }
}

private struct MarkdownInlineText: View {
    let text: MarkdownInline

    var body: some View {
        Text(text.attributed)
            .textSelection(.enabled)
            .font(Design.Typography.body)
            .foregroundStyle(Design.ink)
            .lineSpacing(7)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownList: View {
    let items: [MarkdownListItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    marker(item)
                        .frame(minWidth: 16, alignment: .trailing)
                    MarkdownInlineText(text: item.text)
                }
                .padding(.leading, CGFloat(item.indentation) * 5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func marker(_ item: MarkdownListItem) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? Design.accent : Design.muted)
                .accessibilityLabel(checked ? "已完成" : "未完成")
        } else if let ordinal = item.ordinal {
            Text("\(ordinal).")
                .font(Design.Typography.body.monospacedDigit())
                .foregroundStyle(Design.muted)
        } else {
            Text("•").foregroundStyle(Design.muted)
                .accessibilityHidden(true)
        }
    }
}

private struct MarkdownCodeView: View {
    let code: MarkdownCode
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(code.language.isEmpty ? "代码" : code.language)
                    .font(Design.Typography.caption.monospaced())
                    .foregroundStyle(Design.muted)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: copyCode) {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .font(Design.Typography.caption).controlSize(.regular)
                .help("复制此代码块，保留原始换行和缩进")
                .accessibilityLabel(copied ? "代码已复制" : "复制代码")
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            Divider()
            ScrollView(.horizontal) {
                // String Text bypasses Markdown; code remains verbatim.
                Text(code.text)
                    .textSelection(.enabled)
                    .font(Design.Typography.body.monospaced())
                    .foregroundStyle(Design.ink)
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .scrollIndicators(.automatic, axes: .horizontal)
        }
        .background(Design.soft, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9).strokeBorder(Design.line, lineWidth: 1)
        }
        .onChange(of: code.text) { copied = false }
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setString(code.text, forType: .string)
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        ViewThatFits(in: .horizontal) {
            alignedTable.frame(minWidth: minimumReadableWidth)
            compactTable
        }
    }

    private var minimumReadableWidth: CGFloat {
        CGFloat(table.header.cells.count) * 92 + CGFloat(max(0, table.header.cells.count - 1)) * 12 + 24
    }
    private var alignedTable: some View {
        VStack(spacing: 0) {
            MarkdownTableRowView(row: table.header, alignments: table.alignments, header: true)
            ForEach(table.rows) { row in
                MarkdownTableRowView(row: row, alignments: table.alignments, header: false)
            }
        }
        .background(Design.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Design.line, lineWidth: 1) }
    }
    private var compactTable: some View {
        VStack(alignment: .leading, spacing: 12) {
            if table.rows.isEmpty {
                ForEach(table.header.cells) { header in
                    Text(header.text.attributed).font(Design.Typography.body.weight(.semibold))
                        .textSelection(.enabled)
                        .foregroundStyle(Design.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(table.rows) { row in
                    MarkdownCompactTableRow(row: row, header: table.header)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Narrow or many-column tables become labelled rows, without squeezing Chinese
/// into one-character columns or adding page-wide horizontal scrolling.
private struct MarkdownCompactTableRow: View {
    let row: MarkdownTableRow
    let header: MarkdownTableRow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(row.cells) { cell in
                VStack(alignment: .leading, spacing: 4) {
                    Text(header.cells[cell.column].text.attributed)
                        .textSelection(.enabled)
                        .font(Design.Typography.caption.weight(.semibold)).foregroundStyle(Design.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    MarkdownInlineText(text: cell.text)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.soft, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Design.line, lineWidth: 1) }
    }
}

private struct MarkdownTableRowView: View {
    let row: MarkdownTableRow
    let alignments: [MarkdownColumnAlignment]
    let header: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(row.cells) { cell in
                    Text(cell.text.attributed)
                        .textSelection(.enabled)
                        .font(header ? Design.Typography.body.weight(.semibold) : Design.Typography.body)
                        .foregroundStyle(Design.ink)
                        .lineSpacing(6)
                        .multilineTextAlignment(textAlignment(cell.column))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: alignment(cell.column))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(header ? Design.soft : Color.clear)
            Divider()
        }
    }

    private func alignment(_ column: Int) -> Alignment {
        switch alignments[column] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
    private func textAlignment(_ column: Int) -> TextAlignment {
        switch alignments[column] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

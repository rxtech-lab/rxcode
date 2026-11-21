import SwiftUI
import RxCodeCore

struct JSONUITableView: View {
    let table: JSONUITable

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let caption = table.caption {
                Text(caption).font(.caption.weight(.semibold)).foregroundStyle(ClaudeTheme.textSecondary)
            }
            // A grid when it fits the width; on narrow screens each row becomes a block of its own.
            ViewThatFits(in: .horizontal) {
                grid
                stacked
            }
        }
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow {
                ForEach(table.columns) { column in
                    Text(column.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .gridColumnAlignment(horizontal(column))
                }
            }
            ClaudeThemeDivider()
            ForEach(table.rows.indices, id: \.self) { index in
                let row = table.rows[index]
                if row.style == "total" { ClaudeThemeDivider() }
                GridRow {
                    ForEach(table.columns) { column in
                        cell(row.cells[column.key], column: column, style: row.style)
                    }
                }
            }
            if table.hasTotals {
                ClaudeThemeDivider()
                GridRow {
                    ForEach(Array(table.columns.enumerated()), id: \.element.id) { index, column in
                        if let total = table.total(of: column) {
                            Text(JSONUIFormat.text(.number(total), format: column.format, currency: column.currency))
                                .font(.subheadline.weight(.bold))
                                .monospacedDigit()
                        } else if index == 0 {
                            Text(table.totalLabel ?? String(localized: "Total", bundle: .module))
                                .font(.subheadline.weight(.bold))
                        } else {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
            }
        }
    }

    /// The leading text columns title each block; the other columns are its label / value lines.
    private var titleColumns: [JSONUITable.Column] {
        let leading = Array(table.columns.prefix { $0.format == nil || $0.format == "text" })
        return leading.isEmpty ? Array(table.columns.prefix(1)) : Array(leading.prefix(1))
    }

    private var stacked: some View {
        let titles = titleColumns
        let values = table.columns.filter { !titles.contains($0) }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(table.rows.indices, id: \.self) { index in
                let row = table.rows[index]
                let bold = row.style == "emphasis" || row.style == "total"
                VStack(alignment: .leading, spacing: 6) {
                    Text(titles.map { JSONUIFormat.text(row.cells[$0.key]?.value, format: $0.format, currency: $0.currency) }.joined(separator: " · "))
                        .font(.subheadline.weight(bold ? .bold : .semibold))
                        .foregroundStyle(row.style == "muted" ? ClaudeTheme.textSecondary : ClaudeTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(values) { column in
                        let cell = row.cells[column.key]
                        HStack(alignment: .firstTextBaseline) {
                            Text(column.label).foregroundStyle(ClaudeTheme.textSecondary)
                            Spacer(minLength: 8)
                            Text(JSONUIFormat.text(cell?.value, format: column.format, currency: column.currency))
                                .fontWeight(bold ? .bold : .medium)
                                .monospacedDigit()
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(JSONUITone.color(cell?.tone))
                        }
                        .font(.subheadline)
                    }
                }
                .padding(.vertical, 10)
                .accessibilityElement(children: .combine)
                ClaudeThemeDivider()
            }
            if table.hasTotals {
                VStack(alignment: .leading, spacing: 6) {
                    Text(table.totalLabel ?? String(localized: "Total", bundle: .module))
                        .font(.subheadline.weight(.bold))
                    ForEach(table.columns.filter(\.total)) { column in
                        HStack(alignment: .firstTextBaseline) {
                            Text(column.label).foregroundStyle(ClaudeTheme.textSecondary)
                            Spacer(minLength: 8)
                            Text(JSONUIFormat.text(table.total(of: column).map(JSONValue.number), format: column.format, currency: column.currency))
                                .fontWeight(.bold)
                                .monospacedDigit()
                        }
                        .font(.subheadline)
                    }
                }
                .padding(.top, 10)
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private func cell(_ cell: JSONUITable.Cell?, column: JSONUITable.Column, style: String?) -> some View {
        let isNumeric = cell?.value?.numberValue != nil
        VStack(alignment: horizontal(column), spacing: 1) {
            Text(JSONUIFormat.text(cell?.value, format: column.format, currency: column.currency))
                .font(.subheadline.weight(style == "emphasis" || style == "total" ? .bold : .regular))
                .monospacedDigit()
                .foregroundStyle(style == "muted" ? ClaudeTheme.textSecondary : JSONUITone.color(cell?.tone))
                .textSelection(.enabled)
            if let detail = cell?.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .lineLimit(3)
            }
        }
        // Long text wraps in its column; numbers stay on one line.
        .frame(maxWidth: isNumeric ? nil : 240, alignment: Alignment(horizontal: horizontal(column), vertical: .top))
        .fixedSize(horizontal: isNumeric, vertical: true)
    }

    private func horizontal(_ column: JSONUITable.Column) -> HorizontalAlignment {
        switch column.align {
        case "center": .center
        case "trailing": .trailing
        default: .leading
        }
    }
}

struct JSONUIBarChart: View {
    let element: JSONUIElement

    var body: some View {
        let items = element.objects("items")
        let values = items.map { $0["value"]?.numberValue ?? 0 }
        let largest = max(values.map(abs).max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 10) {
            if let title = element.string("title") {
                Text(title).font(.subheadline.weight(.semibold))
            }
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                let tone = item["tone"]?.stringValue
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item["label"]?.stringValue ?? "").font(.subheadline)
                        Spacer(minLength: 8)
                        Text(JSONUIFormat.text(item["value"], format: element.string("format"), currency: element.string("currency")))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                    JSONUIBar(fraction: abs(values[index]) / largest, tint: tone == nil || tone == "default" ? ClaudeTheme.accent : JSONUITone.tint(tone))
                    if let detail = item["detail"]?.stringValue {
                        Text(detail).font(.caption).foregroundStyle(ClaudeTheme.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

struct JSONUIProgress: View {
    let element: JSONUIElement

    var body: some View {
        let value = element.number("value") ?? 0
        let total = max(element.number("total") ?? 100, .ulpOfOne)
        let tone = element.string("tone")
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(element.string("label") ?? "").font(.subheadline)
                Spacer(minLength: 8)
                Text((min(max(value / total, 0), 1)).formatted(.percent.precision(.fractionLength(0))))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            JSONUIBar(fraction: value / total, tint: tone == nil || tone == "default" ? ClaudeTheme.accent : JSONUITone.tint(tone))
            if let detail = element.string("detail") {
                Text(detail).font(.caption).foregroundStyle(ClaudeTheme.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct JSONUIBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        Capsule()
            .fill(ClaudeTheme.surfaceTertiary)
            .frame(height: 8)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(tint)
                        .frame(width: max(8, proxy.size.width * min(max(fraction, 0), 1)))
                }
            }
    }
}

struct JSONUICode: View {
    let element: JSONUIElement

    var body: some View {
        let code = element.string("code") ?? ""
        let fence = String(repeating: "`", count: max(3, (code.components(separatedBy: "\n").map { $0.prefix { $0 == "`" }.count }.max() ?? 0) + 1))
        VStack(alignment: .leading, spacing: 6) {
            if let caption = element.string("caption") {
                Text(caption).font(.caption.weight(.semibold)).foregroundStyle(ClaudeTheme.textSecondary)
            }
            MarkdownContentView(text: "\(fence)\(element.string("language") ?? "")\n\(code)\n\(fence)")
                .textSelection(.enabled)
        }
    }
}

struct JSONUIImage: View {
    let url: URL
    let caption: String?
    let aspectRatio: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(aspectRatio, contentMode: .fit)
                .overlay {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            Image(systemName: "photo").foregroundStyle(ClaudeTheme.textTertiary)
                        default:
                            ProgressView()
                        }
                    }
                }
                .background(ClaudeTheme.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall, style: .continuous))
            if let caption {
                Text(caption).font(.caption).foregroundStyle(ClaudeTheme.textSecondary)
            }
        }
    }
}

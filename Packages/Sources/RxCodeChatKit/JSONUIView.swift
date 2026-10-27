import SwiftUI
import RxCodeCore

/// Draws a `JSONUISpec` with native components, json-render style: each element's `type` picks a
/// component from `JSONUICatalog`, containers draw their children by id. Unknown types and broken
/// references draw nothing.
public struct JSONUIRenderer: View {
    let spec: JSONUISpec

    private let onSubmit: (([String: JSONValue]) -> Void)?

    public init(spec: JSONUISpec, onSubmit: (([String: JSONValue]) -> Void)? = nil) {
        self.spec = spec
        self.onSubmit = onSubmit
    }

    public var body: some View {
        JSONUIInteractiveHost(spec: spec, onSubmit: onSubmit) { id in
            AnyView(JSONUINode(id: id, spec: spec, depth: 0))
        }
        .id(spec)
    }
}

/// A `show_ui` tool call drawn inline in a chat transcript: its title, the rendered view, and a
/// button opening the call's parameters and result.
public struct JSONUIToolCard: View {
    let toolCall: ToolCall
    let isStreaming: Bool
    @Environment(\.openJSONUIDialog) private var openDialog
    @State private var showsDetails = false

    public init(toolCall: ToolCall, isStreaming: Bool = false) {
        self.toolCall = toolCall
        self.isStreaming = isStreaming
    }

    public var body: some View {
        let payload = JSONUITool.payload(from: toolCall.input)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(payload.title ?? String(localized: "Interactive View", bundle: .module), systemImage: "rectangle.3.group")
                    .font(.system(size: ClaudeTheme.messageSize(14), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    showsDetails = true
                } label: {
                    Image(systemName: "curlybraces")
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(ClaudeTheme.textTertiary)
                .help(String(localized: "Show View JSON", bundle: .module))
                .accessibilityLabel(String(localized: "Show View JSON", bundle: .module))
            }
            content(payload)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ClaudeTheme.surfacePrimary, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium, style: .continuous)
                .strokeBorder(ClaudeTheme.border, lineWidth: BubbleStyle.borderWidth)
        )
        .sheet(isPresented: $showsDetails) {
            ToolActivityDetailView(tool: toolCall, isStreaming: isStreaming)
        }
        #if os(iOS)
        .sensoryFeedback(.selection, trigger: showsDetails)
        #endif
        .accessibilityIdentifier("json-ui-\(toolCall.id)")
    }

    @ViewBuilder
    private func content(_ payload: JSONUITool.Payload) -> some View {
        if let spec = payload.spec, spec.issues.isEmpty {
            if payload.presentation == .dialog, let openDialog {
                JSONUIDialogOpenRow(payload: payload, open: openDialog)
            } else {
                JSONUIRenderer(spec: spec)
            }
        } else if payload.spec == nil && toolCall.result == nil && !toolCall.isError && isStreaming {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Preparing view…", bundle: .module)
                    .font(.callout)
                    .foregroundStyle(ClaudeTheme.textSecondary)
            }
        } else {
            Label {
                Text("This view could not be displayed.", bundle: .module)
                    .font(.callout)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(ClaudeTheme.statusWarning)
            }
            .foregroundStyle(ClaudeTheme.textSecondary)
        }
    }
}

/// One element and, for containers, its children. Children are type-erased: the view is recursive.
private struct JSONUINode: View {
    let id: String
    let spec: JSONUISpec
    let depth: Int
    /// A grid cell: boxed elements stretch to the row's tallest cell.
    var fillsCell = false
    @Environment(\.jsonUIInteraction) private var interaction

    var body: some View {
        if depth < JSONUICatalog.maxDepth, let element = spec.elements[id] {
            content(element)
        }
    }

    @ViewBuilder
    private func content(_ element: JSONUIElement) -> some View {
        switch element.type {
        case "Form":
            VStack(alignment: .leading, spacing: 16) {
                if let title = element.string("title") { Text(title).font(.headline) }
                children(of: element)
            }
            .environment(\.jsonUIFormID, id)
        case "Sheet", "Dialog", "Overlay", "Alert", "ConfirmationDialog":
            EmptyView() // Presented by the host, never stacked into the document.
        case "Button", "TextField", "TextEditor", "Toggle", "Picker", "Slider":
            if let interaction {
                JSONUIControl(id: id, element: element, interaction: interaction)
            }
        case "Stack":
            let spacing = Self.spacing(element.string("gap"))
            if element.string("direction") == "horizontal" {
                HStack(alignment: .top, spacing: spacing) { children(of: element) }
            } else {
                VStack(alignment: .leading, spacing: spacing) { children(of: element) }
            }
        case "Grid":
            grid(element, columns: min(4, max(1, Int(element.number("columns") ?? 2))))
        case "Card":
            JSONUICard(element: element, fillsHeight: fillsCell) { children(of: element) }
        case "Disclosure":
            JSONUIDisclosure(element: element) { children(of: element) }
        case "Tabs":
            JSONUITabs(element: element) { child in
                AnyView(JSONUINode(id: child, spec: spec, depth: depth + 1))
            }
        case "Heading":
            Text(element.string("text") ?? "")
                .font(Self.headingFont(element.number("level")))
                .foregroundStyle(ClaudeTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        case "Text":
            MarkdownContentView(text: element.string("text") ?? "")
                .font(Self.textFont(size: element.string("size"), weight: element.string("weight")))
                .foregroundStyle(JSONUITone.color(element.string("tone")))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case "Badge":
            let tint = JSONUITone.tint(element.string("tone"))
            Text(element.string("text") ?? "")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundStyle(tint)
                .background(tint.opacity(0.14), in: Capsule())
        case "Stat":
            JSONUIStat(element: element, fillsHeight: fillsCell)
        case "Callout":
            JSONUICallout(element: element, fillsHeight: fillsCell)
        case "KeyValue":
            JSONUIKeyValue(element: element)
        case "List":
            JSONUIList(element: element)
        case "Steps":
            JSONUISteps(element: element)
        case "Table":
            JSONUITableView(table: JSONUITable(element))
        case "BarChart":
            JSONUIBarChart(element: element)
        case "Progress":
            JSONUIProgress(element: element)
        case "Code":
            JSONUICode(element: element)
        case "Divider":
            Divider()
        case "Link":
            link(element)
        case "Image":
            if let url = Self.httpsURL(element.string("url")) {
                JSONUIImage(url: url, caption: element.string("caption"), aspectRatio: Self.aspectRatio(element.string("aspect")))
            }
        case "Gallery":
            gallery(element)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func link(_ element: JSONUIElement) -> some View {
        if let url = element.string("url").flatMap(URL.init(string:)), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            Link(destination: url) {
                Label(element.string("title") ?? url.absoluteString, systemImage: "link")
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    @ViewBuilder
    private func gallery(_ element: JSONUIElement) -> some View {
        let images = element.objects("images").compactMap { image -> (URL, String?)? in
            guard let url = Self.httpsURL(image["url"]?.stringValue) else { return nil }
            return (url, image["caption"]?.stringValue)
        }
        if !images.isEmpty {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(images.indices, id: \.self) { index in
                        JSONUIImage(url: images[index].0, caption: images[index].1, aspectRatio: 1)
                            .frame(width: 200)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    /// Rows of equal-height cells: each row is as tall as its tallest cell.
    private func grid(_ element: JSONUIElement, columns count: Int) -> some View {
        let rows = stride(from: 0, to: element.children.count, by: count).map {
            Array(element.children[$0..<min($0 + count, element.children.count)])
        }
        return Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(rows.indices, id: \.self) { index in
                GridRow {
                    ForEach(rows[index], id: \.self) { child in
                        AnyView(JSONUINode(id: child, spec: spec, depth: depth + 1, fillsCell: true))
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    // Keeps a short last row's cells at column width.
                    ForEach(rows[index].count..<count, id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                    }
                }
            }
        }
    }

    private func children(of element: JSONUIElement) -> some View {
        ForEach(element.children, id: \.self) { child in
            AnyView(JSONUINode(id: child, spec: spec, depth: depth + 1))
        }
    }

    private static func httpsURL(_ string: String?) -> URL? {
        guard let url = string.flatMap(URL.init(string:)), url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    private static func aspectRatio(_ aspect: String?) -> CGFloat {
        switch aspect {
        case "square": 1
        case "portrait": 3.0 / 4.0
        default: 16.0 / 9.0
        }
    }

    private static func spacing(_ gap: String?) -> CGFloat {
        switch gap {
        case "none": 0
        case "small": 6
        case "large": 18
        default: 12
        }
    }

    private static func headingFont(_ level: Double?) -> Font {
        switch level {
        case 1: .title2.weight(.bold)
        case 3: .headline
        default: .title3.weight(.semibold)
        }
    }

    private static func textFont(size: String?, weight: String?) -> Font {
        let font: Font = switch size {
        case "small": .footnote
        case "large": .title3
        default: .body
        }
        return switch weight {
        case "semibold": font.weight(.semibold)
        case "bold": font.weight(.bold)
        default: font
        }
    }
}

/// The catalog's tones as colors.
enum JSONUITone {
    /// Text color: tones other than default and muted are tinted.
    static func color(_ tone: String?) -> Color {
        switch tone {
        case "muted": ClaudeTheme.textSecondary
        case nil, "default": ClaudeTheme.textPrimary
        default: tint(tone)
        }
    }

    /// Fill and accent color.
    static func tint(_ tone: String?) -> Color {
        switch tone {
        case "accent": ClaudeTheme.accent
        case "positive", "success", "done": ClaudeTheme.statusSuccess
        case "negative", "failed": ClaudeTheme.statusError
        case "warning": ClaudeTheme.statusWarning
        case "info", "active": ClaudeTheme.statusRunning
        case "tip": .yellow
        default: ClaudeTheme.textSecondary
        }
    }
}

private struct JSONUICard<Content: View>: View {
    let element: JSONUIElement
    var fillsHeight = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        let tone = element.string("tone")
        VStack(alignment: .leading, spacing: 10) {
            if element.string("title") != nil || element.string("subtitle") != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if let title = element.string("title") {
                        Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    }
                    if let subtitle = element.string("subtitle") {
                        Text(subtitle).font(.subheadline).foregroundStyle(ClaudeTheme.textSecondary)
                    }
                }
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .background(
            tone == nil || tone == "default" ? ClaudeTheme.surfaceSecondary : JSONUITone.tint(tone).opacity(0.1),
            in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall, style: .continuous)
        )
    }
}

private struct JSONUIDisclosure<Content: View>: View {
    let element: JSONUIElement
    @ViewBuilder let content: () -> Content
    @State private var isExpanded: Bool

    init(element: JSONUIElement, @ViewBuilder content: @escaping () -> Content) {
        self.element = element
        self.content = content
        _isExpanded = State(initialValue: element.bool("expanded") ?? false)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(element.string("title") ?? "")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ClaudeTheme.textPrimary)
        }
        #if os(iOS)
        .sensoryFeedback(.selection, trigger: isExpanded)
        #endif
    }
}

private struct JSONUITabs: View {
    let element: JSONUIElement
    let child: (String) -> AnyView
    @State private var selection = 0

    var body: some View {
        let labels = element.strings("tabs")
        let count = min(labels.count, element.children.count)
        if count > 0 {
            VStack(alignment: .leading, spacing: 12) {
                Picker(String(localized: "Tabs", bundle: .module), selection: $selection) {
                    ForEach(0..<count, id: \.self) { index in
                        Text(labels[index]).tag(index)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                child(element.children[min(selection, count - 1)])
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            #if os(iOS)
            .sensoryFeedback(.selection, trigger: selection)
            #endif
        }
    }
}

private struct JSONUIStat: View {
    let element: JSONUIElement
    var fillsHeight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(element.string("label") ?? "")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ClaudeTheme.textSecondary)
            Text(JSONUIFormat.text(element.props["value"], format: element.string("format"), currency: element.string("currency")))
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(JSONUITone.color(element.string("tone")))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            if let detail = element.string("detail") {
                Text(detail).font(.caption).foregroundStyle(ClaudeTheme.textSecondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct JSONUICallout: View {
    let element: JSONUIElement
    var fillsHeight = false

    var body: some View {
        let tone = element.string("tone") ?? "info"
        let tint = JSONUITone.tint(tone)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Self.symbol(tone))
                .foregroundStyle(tint)
                .font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                if let title = element.string("title") {
                    Text(title).font(.subheadline.weight(.semibold))
                }
                Text(element.string("text") ?? "")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private static func symbol(_ tone: String) -> String {
        switch tone {
        case "tip": "lightbulb"
        case "warning": "exclamationmark.triangle"
        case "success": "checkmark.seal"
        default: "info.circle"
        }
    }
}

private struct JSONUIKeyValue: View {
    let element: JSONUIElement

    var body: some View {
        let items = element.objects("items")
        VStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                HStack(alignment: .firstTextBaseline) {
                    Text(item["label"]?.stringValue ?? "")
                        .foregroundStyle(ClaudeTheme.textSecondary)
                    Spacer(minLength: 12)
                    Text(JSONUIFormat.text(item["value"], format: item["format"]?.stringValue, currency: item["currency"]?.stringValue))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(JSONUITone.color(item["tone"]?.stringValue))
                        .textSelection(.enabled)
                }
                .font(.subheadline)
                .padding(.vertical, 7)
                .accessibilityElement(children: .combine)
                if index < items.count - 1 { Divider() }
            }
        }
    }
}

private struct JSONUIList: View {
    let element: JSONUIElement

    var body: some View {
        let ordered = element.bool("ordered") ?? false
        let items = element.strings("items")
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ordered ? "\(index + 1)." : "•")
                        .monospacedDigit()
                        .foregroundStyle(ClaudeTheme.textSecondary)
                    MarkdownContentView(text: items[index])
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.subheadline)
            }
        }
    }
}

/// A numbered vertical timeline; each step's status colors its marker.
private struct JSONUISteps: View {
    let element: JSONUIElement

    var body: some View {
        let items = element.objects("items")
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                let status = item["status"]?.stringValue
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        marker(index: index, status: status)
                        if index < items.count - 1 {
                            Rectangle()
                                .fill(ClaudeTheme.border)
                                .frame(width: 2)
                                .frame(maxHeight: .infinity)
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item["title"]?.stringValue ?? "")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(status == "pending" ? ClaudeTheme.textSecondary : ClaudeTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = item["detail"]?.stringValue {
                            MarkdownContentView(text: detail)
                                .font(.callout)
                                .foregroundStyle(ClaudeTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.bottom, index < items.count - 1 ? 14 : 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private func marker(index: Int, status: String?) -> some View {
        let tint = status == nil ? ClaudeTheme.accent : JSONUITone.tint(status)
        ZStack {
            Circle().fill(tint.opacity(status == "pending" ? 0.12 : 0.18))
            switch status {
            case "done":
                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(tint)
            case "failed":
                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(tint)
            default:
                Text("\(index + 1)").font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(tint)
            }
        }
        .frame(width: 24, height: 24)
    }
}

private struct JSONUITableView: View {
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
            Divider()
            ForEach(table.rows.indices, id: \.self) { index in
                let row = table.rows[index]
                if row.style == "total" { Divider() }
                GridRow {
                    ForEach(table.columns) { column in
                        cell(row.cells[column.key], column: column, style: row.style)
                    }
                }
            }
            if table.hasTotals {
                Divider()
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
                Divider()
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

private struct JSONUIBarChart: View {
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

private struct JSONUIProgress: View {
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

private struct JSONUICode: View {
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

private struct JSONUIImage: View {
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

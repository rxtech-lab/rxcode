import RxCodeCore
import SwiftUI

/// A dropdown control for choosing an SF Symbol. Shows a live preview of the
/// current selection and opens a searchable grid of common symbols. Users can
/// also type any symbol name directly for symbols not in the curated list.
struct SFSymbolPicker: View {
    @Binding var symbol: String

    @State private var isPresented = false
    @State private var query = ""

    /// Curated list of symbols that read well as menu-action icons.
    private static let symbols: [String] = [
        "bolt", "bolt.fill", "star", "star.fill", "heart", "heart.fill",
        "flag", "flag.fill", "bell", "bookmark", "tag", "tag.fill",
        "paperplane", "paperplane.fill", "arrow.up.right", "arrow.up.right.square",
        "link", "globe", "network", "terminal", "hammer", "wrench.and.screwdriver",
        "gearshape", "gearshape.fill", "slider.horizontal.3",
        "doc", "doc.text", "doc.on.doc", "folder", "tray", "tray.full",
        "square.and.arrow.up", "square.and.arrow.down", "trash", "pencil",
        "plus", "plus.circle", "checkmark", "checkmark.circle", "xmark", "xmark.circle",
        "magnifyingglass", "message", "bubble.left", "bubble.left.and.bubble.right",
        "envelope", "phone", "calendar", "clock", "alarm",
        "person", "person.2", "person.crop.circle", "lock", "lock.open", "key",
        "cloud", "icloud", "arrow.triangle.2.circlepath", "arrow.clockwise",
        "play", "play.fill", "pause", "stop", "forward", "backward",
        "sparkles", "wand.and.stars", "lightbulb", "lightbulb.fill",
        "exclamationmark.triangle", "info.circle", "questionmark.circle",
        "command", "ellipsis", "ellipsis.rectangle", "list.bullet", "list.bullet.rectangle",
        "chart.bar", "chart.line.uptrend.xyaxis", "curlybraces",
        "chevron.left.forwardslash.chevron.right", "brain", "brain.head.profile",
        "cpu", "server.rack", "externaldrive", "memorychip",
        "antenna.radiowaves.left.and.right", "wifi", "shippingbox", "cube",
        "flame", "drop", "leaf", "moon", "sun.max", "bolt.horizontal",
    ]

    private var filtered: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Self.symbols }
        return Self.symbols.filter { $0.contains(q) }
    }

    private var hasSymbol: Bool { !symbol.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: hasSymbol ? symbol : "questionmark.square.dashed")
                    .font(.system(size: ClaudeTheme.size(13)))
                    .foregroundStyle(hasSymbol ? ClaudeTheme.accent : Color.secondary)
                    .frame(width: 18)
                Text(verbatim: hasSymbol ? symbol : "Choose…")
                    .font(.system(size: ClaudeTheme.size(12), design: .monospaced))
                    .foregroundStyle(hasSymbol ? .primary : .secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: ClaudeTheme.size(9)))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(NSColor.separatorColor)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            pickerBody
        }
    }

    private var pickerBody: some View {
        VStack(spacing: 10) {
            TextField("Symbol name", text: $symbol, prompt: Text(verbatim: "e.g. bolt"))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: ClaudeTheme.size(12), design: .monospaced))

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
                TextField("Search symbols", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: ClaudeTheme.size(12)))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 6), count: 6), spacing: 6) {
                    ForEach(filtered, id: \.self) { name in
                        symbolCell(name)
                    }
                }
                .padding(2)
            }
            .frame(height: 220)

            if filtered.isEmpty {
                Text("No matches. Type a name above to use it anyway.")
                    .font(.system(size: ClaudeTheme.size(10)))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private func symbolCell(_ name: String) -> some View {
        let isSelected = symbol == name
        return Button {
            symbol = name
            isPresented = false
        } label: {
            Image(systemName: name)
                .font(.system(size: ClaudeTheme.size(15)))
                .frame(width: 38, height: 34)
                .background(isSelected ? ClaudeTheme.accent.opacity(0.18) : Color(NSColor.controlBackgroundColor))
                .foregroundStyle(isSelected ? ClaudeTheme.accent : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isSelected ? ClaudeTheme.accent : Color(NSColor.separatorColor), lineWidth: isSelected ? 1.5 : 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
    }
}

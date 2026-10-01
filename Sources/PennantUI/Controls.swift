import PennantCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

// Reusable inputs. The rule across Pennant: choose from something before typing something.

// MARK: - Buttons

public enum PennantButtonKind { case primary, secondary, destructive, ghost }

/// Pill buttons: black primary, grey secondary, red destructive, borderless ghost.
public struct PennantButtonStyle: ButtonStyle {
    var kind: PennantButtonKind
    var compact: Bool
    @Environment(\.isEnabled) private var isEnabled

    public init(_ kind: PennantButtonKind = .secondary, compact: Bool = false) { self.kind = kind; self.compact = compact }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .zoomed(.callout).weight(.medium) : .zoomed(.body).weight(.medium))
            .padding(.horizontal, compact ? 12 : 18)
            .padding(.vertical, compact ? 6 : 9)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }

    private var foreground: Color {
        guard isEnabled else { return PennantTheme.disabledButtonText }
        switch kind {
        case .primary: return PennantTheme.primaryButtonText
        case .secondary, .ghost: return PennantTheme.ink
        case .destructive: return .white
        }
    }

    private var background: Color {
        guard isEnabled else { return kind == .ghost ? .clear : PennantTheme.disabledButton }
        switch kind {
        case .primary: return PennantTheme.primaryButton
        case .secondary: return PennantTheme.fieldBackground
        case .destructive: return Color(hex: "#E5484D")
        case .ghost: return .clear
        }
    }
}

public extension ButtonStyle where Self == PennantButtonStyle {
    static var pennantPrimary: PennantButtonStyle { PennantButtonStyle(.primary) }
    static var pennantSecondary: PennantButtonStyle { PennantButtonStyle(.secondary) }
    static var pennantDestructive: PennantButtonStyle { PennantButtonStyle(.destructive) }
    static var pennantGhost: PennantButtonStyle { PennantButtonStyle(.ghost) }
    static var pennantCompact: PennantButtonStyle { PennantButtonStyle(.secondary, compact: true) }
    static var pennantPrimaryCompact: PennantButtonStyle { PennantButtonStyle(.primary, compact: true) }
    static var pennantGhostCompact: PennantButtonStyle { PennantButtonStyle(.ghost, compact: true) }
    static var pennantDestructiveCompact: PennantButtonStyle { PennantButtonStyle(.destructive, compact: true) }
}

/// Round icon button for toolbars and headers (the "+" in a sidebar header, the mic in a composer).
public struct IconButtonStyle: ButtonStyle {
    var filled: Bool
    var size: CGFloat
    @State private var hovering = false
    public init(filled: Bool = false, size: CGFloat = 28) { self.filled = filled; self.size = size }
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.zoomed(size: size * 0.5, weight: .medium))
            .foregroundStyle(filled ? PennantTheme.primaryButtonText : PennantTheme.inkSecondary)
            .frame(width: size, height: size)
            .background(filled ? PennantTheme.primaryButton : (hovering ? PennantTheme.hover : .clear), in: Circle())
            .contentShape(Circle())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering = $0 }
    }
}

public extension ButtonStyle where Self == IconButtonStyle {
    static var pennantIcon: IconButtonStyle { IconButtonStyle() }
}

// MARK: - Fields

/// Rounded field container with the theme's border. Wrap any control to make it look like a Pennant field.
public struct FieldContainer: ViewModifier {
    var focused: Bool
    public func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(PennantTheme.cardElevated, in: RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous).stroke(focused ? PennantTheme.ink.opacity(0.35) : PennantTheme.border, lineWidth: 1))
    }
}

public extension View {
    func pennantField(focused: Bool = false) -> some View { modifier(FieldContainer(focused: focused)) }
}

/// Caption above a field: "Name", "Repeat".
public struct FieldLabel: View {
    var text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text).font(.zoomed(.subheadline)).foregroundStyle(PennantTheme.inkSecondary)
    }
}

/// A labelled text field in Pennant's style. Use only where free text is genuinely the input (names, prompts).
public struct PennantTextField: View {
    var label: String?
    var placeholder: String
    @Binding var text: String
    var lines: ClosedRange<Int>
    @FocusState private var focused: Bool

    public init(_ label: String? = nil, placeholder: String, text: Binding<String>, lines: ClosedRange<Int> = 1 ... 1) {
        self.label = label
        self.placeholder = placeholder
        _text = text
        self.lines = lines
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label { FieldLabel(label) }
            TextField(placeholder, text: $text, axis: lines.upperBound > 1 ? .vertical : .horizontal)
                .textFieldStyle(.plain)
                .lineLimit(lines)
                .focused($focused)
                .pennantField(focused: focused)
        }
    }
}

/// Pill search field with a magnifier and a clear button.
public struct SearchField: View {
    var placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool
    public init(_ placeholder: String = "Search", text: Binding<String>) { self.placeholder = placeholder; _text = text }
    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(PennantTheme.inkTertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(PennantTheme.inkTertiary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(PennantTheme.fieldBackground, in: Capsule())
    }
}

// MARK: - Choice controls

/// One selectable option for menus and autocomplete lists.
public struct ChoiceOption<Value: Hashable>: Identifiable {
    public var value: Value
    public var title: String
    public var subtitle: String?
    public var symbol: String?
    public var id: Value { value }
    public init(_ value: Value, title: String, subtitle: String? = nil, symbol: String? = nil) {
        self.value = value; self.title = title; self.subtitle = subtitle; self.symbol = symbol
    }
}

/// A dropdown that looks like a field: current choice on the left, chevron on the right. Backed by `Menu`.
public struct ChoiceMenu<Value: Hashable>: View {
    var label: String?
    @Binding var selection: Value
    var options: [ChoiceOption<Value>]
    var placeholder: String

    public init(_ label: String? = nil, selection: Binding<Value>, options: [ChoiceOption<Value>], placeholder: String = "Choose…") {
        self.label = label
        _selection = selection
        self.options = options
        self.placeholder = placeholder
    }

    private var current: ChoiceOption<Value>? { options.first { $0.value == selection } }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label { FieldLabel(label) }
            Menu {
                ForEach(options) { o in
                    Button {
                        selection = o.value
                    } label: {
                        if let s = o.symbol { Label(o.title, systemImage: s) } else { Text(o.title) }
                        if let sub = o.subtitle { Text(sub) }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    if let s = current?.symbol { Image(systemName: s).foregroundStyle(PennantTheme.inkSecondary) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(current?.title ?? placeholder).foregroundStyle(current == nil ? PennantTheme.inkTertiary : PennantTheme.ink)
                        if let sub = current?.subtitle { Text(sub).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary) }
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(.zoomed(.caption).weight(.semibold)).foregroundStyle(PennantTheme.inkTertiary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .pennantField()
        }
    }
}

/// A row of pill chips. Single choice when `selection` is one value; use `MultiChipRow` for sets.
public struct ChipRow<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [ChoiceOption<Value>]
    public init(selection: Binding<Value>, options: [ChoiceOption<Value>]) { _selection = selection; self.options = options }
    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(options) { o in
                    ChipButton(title: o.title, symbol: o.symbol, selected: o.value == selection) { selection = o.value }
                }
            }
        }
    }
}

public struct MultiChipRow<Value: Hashable>: View {
    @Binding var selection: Set<Value>
    var options: [ChoiceOption<Value>]
    public init(selection: Binding<Set<Value>>, options: [ChoiceOption<Value>]) { _selection = selection; self.options = options }
    public var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(options) { o in
                ChipButton(title: o.title, symbol: o.symbol, selected: selection.contains(o.value)) {
                    if selection.contains(o.value) { selection.remove(o.value) } else { selection.insert(o.value) }
                }
            }
        }
    }
}

public struct ChipButton: View {
    var title: String
    var symbol: String?
    var selected: Bool
    var action: () -> Void
    public init(title: String, symbol: String? = nil, selected: Bool, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.selected = selected; self.action = action
    }
    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.zoomed(.caption)) }
                Text(title).font(.zoomed(.callout).weight(selected ? .semibold : .regular))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? PennantTheme.primaryButtonText : PennantTheme.ink)
            .background(selected ? PennantTheme.primaryButton : PennantTheme.fieldBackground, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Wraps children onto new lines, for chip sets.
public struct FlowLayout: Layout {
    var spacing: CGFloat
    public init(spacing: CGFloat = 6) { self.spacing = spacing }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x)
        }
        return CGSize(width: width == .infinity ? maxX : width, height: y + rowHeight)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > bounds.width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            s.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Autocomplete

/// A text field that suggests as you type. Suggestions render inline under (or above) the field, so it works
/// inside sheets without stealing focus. Arrow keys move, Return picks, Escape closes.
/// Place it in a plain VStack (not a `Form`), and give the parent `.scrollClipDisabled()` if it scrolls.
public struct AutocompleteField<Value: Hashable>: View {
    var label: String?
    var placeholder: String
    @Binding var text: String
    var suggestions: (String) -> [ChoiceOption<Value>]
    var onPick: (ChoiceOption<Value>) -> Void
    var opensUpward: Bool
    var maxRows: Int
    @FocusState private var focused: Bool
    @State private var highlighted = 0
    @State private var dismissed = false

    public init(
        _ label: String? = nil,
        placeholder: String,
        text: Binding<String>,
        opensUpward: Bool = false,
        maxRows: Int = 6,
        suggestions: @escaping (String) -> [ChoiceOption<Value>],
        onPick: @escaping (ChoiceOption<Value>) -> Void
    ) {
        self.label = label
        self.placeholder = placeholder
        _text = text
        self.opensUpward = opensUpward
        self.maxRows = maxRows
        self.suggestions = suggestions
        self.onPick = onPick
    }

    private var visible: [ChoiceOption<Value>] {
        guard focused, !dismissed else { return [] }
        return Array(suggestions(text).prefix(maxRows))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label { FieldLabel(label) }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .pennantField(focused: focused)
                .onChange(of: text) { _, _ in dismissed = false; highlighted = 0 }
                #if os(macOS)
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.return) { pickHighlighted() }
                .onKeyPress(.tab) { pickHighlighted() }
                .onKeyPress(.escape) { dismissed = true; return .handled }
                #endif
                .overlay(alignment: opensUpward ? .bottomLeading : .topLeading) {
                    let items = visible
                    if !items.isEmpty {
                        SuggestionList(items: items, highlighted: highlighted) { pick($0) }
                            .offset(y: opensUpward ? -46 : 46)
                            .zIndex(50)
                    }
                }
        }
        .zIndex(visible.isEmpty ? 0 : 50)
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        let items = visible
        guard !items.isEmpty else { return .ignored }
        highlighted = (highlighted + delta + items.count) % items.count
        return .handled
    }

    private func pickHighlighted() -> KeyPress.Result {
        let items = visible
        guard !items.isEmpty, highlighted < items.count else { return .ignored }
        pick(items[highlighted])
        return .handled
    }

    private func pick(_ item: ChoiceOption<Value>) {
        text = item.title
        dismissed = true
        onPick(item)
    }
}

struct SuggestionList<Value: Hashable>: View {
    var items: [ChoiceOption<Value>]
    var highlighted: Int
    var pick: (ChoiceOption<Value>) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                Button { pick(item) } label: {
                    HStack(spacing: 8) {
                        if let s = item.symbol { Image(systemName: s).foregroundStyle(PennantTheme.inkSecondary).frame(width: 16) }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).foregroundStyle(PennantTheme.ink)
                            if let sub = item.subtitle { Text(sub).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary) }
                        }
                        .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(i == highlighted ? PennantTheme.selection : .clear, in: RoundedRectangle(cornerRadius: PennantTheme.radiusSmall, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(PennantTheme.cardElevated, in: RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous).stroke(PennantTheme.border))
        .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
        .frame(maxWidth: 420, alignment: .leading)
    }
}

// MARK: - Searchable picker (large lists)

/// For lists too long for a menu (time zones, models, paths): a field that opens a popover with a search box.
public struct SearchablePicker<Value: Hashable>: View {
    var label: String?
    @Binding var selection: Value?
    var options: [ChoiceOption<Value>]
    var placeholder: String
    var allowsCustom: ((String) -> Value?)?
    @State private var open = false
    @State private var query = ""

    public init(_ label: String? = nil, selection: Binding<Value?>, options: [ChoiceOption<Value>], placeholder: String = "Choose…", allowsCustom: ((String) -> Value?)? = nil) {
        self.label = label
        _selection = selection
        self.options = options
        self.placeholder = placeholder
        self.allowsCustom = allowsCustom
    }

    private var current: ChoiceOption<Value>? { options.first { $0.value == selection } }

    private var filtered: [ChoiceOption<Value>] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Array(options.prefix(60)) }
        return options.filter { $0.title.lowercased().contains(q) || ($0.subtitle?.lowercased().contains(q) ?? false) }.prefix(60).map { $0 }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label { FieldLabel(label) }
            Button { open.toggle() } label: {
                HStack(spacing: 8) {
                    if let s = current?.symbol { Image(systemName: s).foregroundStyle(PennantTheme.inkSecondary) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(current?.title ?? customTitle ?? placeholder).foregroundStyle(selection == nil ? PennantTheme.inkTertiary : PennantTheme.ink)
                        if let sub = current?.subtitle { Text(sub).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary) }
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(.zoomed(.caption).weight(.semibold)).foregroundStyle(PennantTheme.inkTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pennantField()
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(spacing: 8) {
                    SearchField("Search", text: $query)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(filtered) { o in
                                Button {
                                    selection = o.value; open = false; query = ""
                                } label: {
                                    HStack(spacing: 8) {
                                        if let s = o.symbol { Image(systemName: s).foregroundStyle(PennantTheme.inkSecondary).frame(width: 16) }
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(o.title).foregroundStyle(PennantTheme.ink)
                                            if let sub = o.subtitle { Text(sub).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary) }
                                        }
                                        Spacer()
                                        if o.value == selection { Image(systemName: "checkmark").font(.zoomed(.caption).weight(.semibold)) }
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            if let allowsCustom, !query.isEmpty, !exactMatch, let v = allowsCustom(query) {
                                Button {
                                    selection = v; open = false; query = ""
                                } label: {
                                    Label("Use \"\(query)\"", systemImage: "plus").padding(.horizontal, 8).padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                            }
                            if filtered.isEmpty, allowsCustom == nil {
                                Text("No matches").font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary).padding(8)
                            }
                        }
                    }
                    .frame(minHeight: 120, maxHeight: 280)
                }
                .padding(10)
                .frame(width: 320)
            }
        }
    }

    /// True when an option's title or value already equals the typed text, so no "Use …" row is needed.
    private var exactMatch: Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return options.contains { $0.title.caseInsensitiveCompare(q) == .orderedSame || String(describing: $0.value).caseInsensitiveCompare(q) == .orderedSame }
    }

    private var customTitle: String? {
        guard let selection, current == nil else { return nil }
        return String(describing: selection)
    }
}

/// Time zone chooser backed by the searchable picker: city, region, and current offset.
public struct TimeZoneField: View {
    @Binding var identifier: String
    var label: String?
    public init(_ label: String? = "Time zone", identifier: Binding<String>) { self.label = label; _identifier = identifier }

    static let options: [ChoiceOption<String>] = {
        let now = Date()
        return TimeZone.knownTimeZoneIdentifiers.compactMap { id -> ChoiceOption<String>? in
            guard let tz = TimeZone(identifier: id) else { return nil }
            let parts = id.split(separator: "/")
            let city = parts.last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? id
            let region = parts.dropLast().joined(separator: " / ")
            let offset = tz.secondsFromGMT(for: now)
            let sign = offset >= 0 ? "+" : "−"
            let hh = abs(offset) / 3600, mm = (abs(offset) % 3600) / 60
            let off = String(format: "GMT%@%d%@", sign, hh, mm == 0 ? "" : String(format: ":%02d", mm))
            return ChoiceOption(id, title: city, subtitle: [region, off].filter { !$0.isEmpty }.joined(separator: " · "))
        }
        .sorted { $0.title < $1.title }
    }()

    public var body: some View {
        SearchablePicker(label, selection: Binding(get: { identifier.isEmpty ? nil : identifier }, set: { identifier = $0 ?? TimeZone.current.identifier }),
                         options: Self.options, placeholder: TimeZone.current.identifier)
    }
}

// MARK: - Avatar pickers

/// The row of colour dots with a ring on the chosen one.
public struct ColorDots: View {
    @Binding var hex: String
    var dotSize: CGFloat
    public init(hex: Binding<String>, dotSize: CGFloat = 26) { _hex = hex; self.dotSize = dotSize }
    public var body: some View {
        HStack(spacing: 10) {
            ForEach(PennantPalette.swatches) { s in
                let selected = s.hex.caseInsensitiveCompare(hex) == .orderedSame
                Button { hex = s.hex } label: {
                    Circle()
                        .fill(s.color)
                        .frame(width: dotSize, height: dotSize)
                        .padding(3)
                        .overlay(Circle().stroke(selected ? s.color : .clear, lineWidth: 2))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(s.name)
                .accessibilityLabel(s.name)
            }
        }
    }
}

/// The grid of job symbols, each on a flag in the current colour, with a ring on the chosen one.
public struct GlyphPicker: View {
    @Binding var glyph: AgentGlyph
    var hex: String
    var size: CGFloat
    public init(glyph: Binding<AgentGlyph>, hex: String, size: CGFloat = 30) { _glyph = glyph; self.hex = hex; self.size = size }
    public var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: size + 14), spacing: 6)], spacing: 6) {
            ForEach(AgentGlyph.allCases) { g in
                Button { glyph = g } label: {
                    AgentTile(glyph: g, hex: hex, size: size)
                        .padding(5)
                        .background(glyph == g ? PennantTheme.fieldBackground : .clear, in: RoundedRectangle(cornerRadius: PennantTheme.radiusSmall, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: PennantTheme.radiusSmall, style: .continuous).stroke(glyph == g ? PennantTheme.ink : .clear, lineWidth: 1.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(g.title)
                .accessibilityLabel(g.title)
            }
        }
    }
}

// MARK: - Cards and rows

/// Selectable list row with Pennant's rounded selection, for custom sidebars and lists outside `List`.
public struct SelectableRow<Content: View>: View {
    var selected: Bool
    var action: () -> Void
    var content: Content
    @State private var hovering = false
    public init(selected: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.selected = selected; self.action = action; self.content = content()
    }
    public var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? PennantTheme.selection : (hovering ? PennantTheme.hover : .clear), in: RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: PennantTheme.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Header line for a pane: title on the left, actions on the right.
public struct PaneHeader<Trailing: View>: View {
    var title: String
    var trailing: Trailing
    public init(_ title: String, @ViewBuilder trailing: () -> Trailing) { self.title = title; self.trailing = trailing() }
    public var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.zoomed(.headline)).foregroundStyle(PennantTheme.ink)
            Spacer()
            trailing
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }
}

public extension PaneHeader where Trailing == EmptyView {
    init(_ title: String) { self.init(title) { EmptyView() } }
}

/// Empty-state block: a mark, a line, and an optional action.
public struct EmptyState<Actions: View>: View {
    var title: String
    var message: String
    var actions: Actions
    public init(title: String, message: String, @ViewBuilder actions: () -> Actions) { self.title = title; self.message = message; self.actions = actions() }
    public var body: some View {
        VStack(spacing: 10) {
            PennantMark(size: 56)
            Text(title).font(.zoomed(.title3).weight(.semibold)).foregroundStyle(PennantTheme.ink)
            Text(message).font(.zoomed(.callout)).foregroundStyle(PennantTheme.inkSecondary).multilineTextAlignment(.center).frame(maxWidth: 320)
            actions.padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

public extension EmptyState where Actions == EmptyView {
    init(title: String, message: String) { self.init(title: title, message: message) { EmptyView() } }
}

// MARK: - Paths

/// A folder or file path shown as a field with a Choose… button (NSOpenPanel on the Mac).
public struct PathField: View {
    var label: String?
    @Binding var path: String
    var directories: Bool
    var placeholder: String
    public init(_ label: String? = nil, path: Binding<String>, directories: Bool = true, placeholder: String = "Choose a folder…") {
        self.label = label; _path = path; self.directories = directories; self.placeholder = placeholder
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label { FieldLabel(label) }
            HStack(spacing: 8) {
                Image(systemName: directories ? "folder" : "doc").foregroundStyle(PennantTheme.inkSecondary)
                Text(path.isEmpty ? placeholder : abbreviated).foregroundStyle(path.isEmpty ? PennantTheme.inkTertiary : PennantTheme.ink).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                #if os(macOS)
                Button("Choose…") { choose() }.buttonStyle(.pennantCompact)
                #endif
            }
            .pennantField()
        }
    }

    private var abbreviated: String { (path as NSString).abbreviatingWithTildeInPath }

    #if os(macOS)
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directories
        panel.canChooseFiles = !directories
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
    #endif
}

// MARK: - Disclosure

/// A disclosure whose whole header row toggles it. SwiftUI's `DisclosureGroup` on macOS only reacts to its
/// small triangle, which reads as "nothing happens" when the label is clicked.
public struct PennantDisclosure<Content: View>: View {
    var title: String
    var subtitle: String?
    @Binding var isExpanded: Bool
    var content: Content

    public init(_ title: String, subtitle: String? = nil, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        _isExpanded = isExpanded
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.zoomed(.caption).weight(.semibold))
                        .foregroundStyle(PennantTheme.inkTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.zoomed(.callout)).foregroundStyle(PennantTheme.ink)
                        if let subtitle { Text(subtitle).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary) }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            if isExpanded {
                content
                    .padding(.top, 4)
                    .transition(.opacity)
            }
        }
    }
}

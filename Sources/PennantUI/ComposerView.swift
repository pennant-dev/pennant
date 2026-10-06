import PennantClientKit
import PennantCore
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#else
import AppKit
#endif

/// The message pill at the bottom of a conversation: a "+" menu on the left, the text on the middle,
/// and a round send button on the right. Return sends; Shift+Return inserts a newline on the Mac.
///
/// Typing "/" at the start lists the conversation's commands and enabled skills. /clear starts the conversation fresh
/// and /compact folds it into a summary; they run here and never reach Pennant. Picking a skill writes the start of a
/// sentence into the draft ("Use the skill “Inbox triage”: ") for the user to finish.
public struct ComposerView: View {
    @Environment(\.hostSession) private var session
    @Binding var text: String
    @Binding var attachments: [ComposerAttachment]
    var placeholder: String
    var isEnabled: Bool
    var onSend: () -> Void
    var conversationID: ConversationID?
    var onNewConversation: (() -> Void)?
    /// Talk mode on or off, in the Pennant chat; nil elsewhere.
    var onTalk: (() -> Void)?
    var talking = false

    @FocusState private var focused: Bool
    @State private var highlighted = 0
    @State private var suggestionsDismissed = false
    @State private var note: String?
    @State private var noteIsError = false
    @State private var showImporter = false
    @State private var dropTargeted = false
    #if os(iOS)
    @State private var showPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    #endif

    /// - Parameters:
    ///   - conversationID: the open conversation, for /clear and /compact. `nil` for a new one.
    ///   - onNewConversation: what "New conversation" in the "+" menu does. Hidden when `nil`.
    public init(
        text: Binding<String>,
        attachments: Binding<[ComposerAttachment]> = .constant([]),
        placeholder: String = "Message…",
        isEnabled: Bool = true,
        onSend: @escaping () -> Void,
        conversationID: ConversationID? = nil,
        onNewConversation: (() -> Void)? = nil,
        onTalk: (() -> Void)? = nil,
        talking: Bool = false
    ) {
        _text = text
        _attachments = attachments
        self.placeholder = placeholder
        self.isEnabled = isEnabled
        self.onSend = onSend
        self.conversationID = conversationID
        self.onNewConversation = onNewConversation
        self.onTalk = onTalk
        self.talking = talking
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let note {
                HStack(spacing: 6) {
                    Image(systemName: noteIsError ? "exclamationmark.circle" : "info.circle")
                    Text(note).lineLimit(2)
                    Spacer(minLength: 0)
                    Button { self.note = nil; noteIsError = false } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss")
                }
                .font(.zoomed(.caption))
                .foregroundStyle(noteIsError ? ShellPalette.danger : PennantTheme.inkSecondary)
                .padding(.horizontal, 14)
            }
            if !attachments.isEmpty {
                AttachmentStrip(attachments: $attachments)
            }
            pill
                .overlay {
                    if dropTargeted {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(PennantTheme.brand, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    }
                }
                .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
                    accept(providers)
                    return true
                }
                .overlay(alignment: .top) {
                    let items = suggestions
                    if !items.isEmpty {
                        SuggestionList(items: items, highlighted: min(highlighted, items.count - 1)) { pick($0) }
                            .alignmentGuide(.top) { d in d[.bottom] + 8 }
                            .padding(.leading, 4)
                    }
                }
                .zIndex(10)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { for url in urls { attach(fileURL: url) } }
        }
        #if os(iOS)
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 6, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            for item in items {
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        attach(data: data, fileName: "Photo.jpg", type: item.supportedContentTypes.first ?? .jpeg)
                    }
                }
            }
        }
        #endif
        #if os(macOS)
        .onAppear { focused = true }
        #endif
        .onChange(of: text) { _, new in
            suggestionsDismissed = false
            highlighted = 0
            if new.hasPrefix("/") { ensureSkillsLoaded() }
            // Progress notes go away as soon as the user types again; an error stays until dismissed.
            if !noteIsError, !new.isEmpty { note = nil }
        }
    }

    // MARK: Pill

    private var pill: some View {
        HStack(alignment: .bottom, spacing: 6) {
            plusMenu
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.zoomed(.body))
                .foregroundStyle(PennantTheme.ink)
                .lineLimit(1 ... 8)
                .focused($focused)
                .padding(.vertical, 7)
                .disabled(!isEnabled)
                #if os(macOS)
                // ⌘V with an image (and no text) on the clipboard attaches the image; text pastes as usual.
                .onKeyPress(characters: ["v"], phases: .down) { press in
                    guard press.modifiers == .command, NSPasteboard.general.string(forType: .string) == nil,
                          let data = AttachmentPrep.pasteboardImage() else { return .ignored }
                    attach(data: data, fileName: "Pasted image.png", type: .png)
                    return .handled
                }
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.tab) { pickHighlighted() }
                .onKeyPress(.escape) {
                    guard !suggestions.isEmpty else { return .ignored }
                    suggestionsDismissed = true
                    return .handled
                }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    if pickHighlighted() == .handled { return .handled }
                    send()
                    return .handled
                }
                #else
                .submitLabel(.send)
                .onSubmit { send() }
                // Return sends, so the keyboard needs its own way down.
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { focused = false }.font(.zoomed(.body).weight(.semibold))
                    }
                }
                #endif
            if onTalk != nil { talkButton }
            sendButton
        }
        .padding(6)
        .background(PennantTheme.fieldBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var plusMenu: some View {
        Menu {
            if let onNewConversation {
                Button("New conversation", systemImage: "square.and.pencil") { onNewConversation() }
            }
            Divider()
            Button("Attach photo or file…", systemImage: "paperclip") { showImporter = true }
            #if os(iOS)
            Button("Photo library", systemImage: "photo.on.rectangle") { showPhotos = true }
            #else
            Button("Paste image", systemImage: "doc.on.clipboard") { pasteImage() }
            #endif
            Button("Ask for a screenshot", systemImage: "camera.viewfinder") { askForScreenshot() }
            Button("Commands and skills…", systemImage: "wand.and.stars") { begin(with: "/") }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.button)
        .buttonStyle(IconButtonStyle(size: 32))
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!isEnabled)
        .help("More")
        .accessibilityLabel("More")
    }

    private var talkButton: some View {
        Button { onTalk?() } label: {
            Image(systemName: talking ? "waveform.circle.fill" : "waveform")
                .font(.zoomed(size: 15, weight: .semibold))
                .foregroundStyle(talking ? PennantTheme.primaryButtonText : PennantTheme.ink)
                .frame(width: 32, height: 32)
                .background(talking ? PennantTheme.primaryButton : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled && !talking)
        .keyboardShortcut("t", modifiers: [.command, .shift])
        .help(talking ? "Stop talking (⇧⌘T)" : "Talk to Pennant (⇧⌘T)")
        .accessibilityLabel(talking ? "Stop Talk mode" : "Talk to Pennant")
    }

    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up")
                .font(.zoomed(size: 15, weight: .semibold))
                .foregroundStyle(canSend ? PennantTheme.primaryButtonText : PennantTheme.disabledButtonText)
                .frame(width: 32, height: 32)
                .background(canSend ? PennantTheme.primaryButton : PennantTheme.disabledButton, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .keyboardShortcut(.return, modifiers: .command)
        .animation(.easeOut(duration: 0.15), value: canSend)
        .help("Send")
        .accessibilityLabel("Send")
    }

    private var canSend: Bool {
        guard isEnabled, !attachments.contains(where: \.isUploading) else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachments.contains { $0.ready != nil }
    }

    private func send() {
        if let command = typedCommand { return run(command) }
        guard canSend else { return }
        onSend()
    }

    // MARK: "+" menu actions

    private func begin(with prefix: String) {
        text = prefix
        suggestionsDismissed = false
        focused = true
        if prefix == "/" { ensureSkillsLoaded() }
    }

    /// There is no attachment plumbing yet, so this asks the agent to take the screenshot itself.
    private func askForScreenshot() {
        let lead = "Take a screenshot and "
        if !text.hasPrefix(lead) { text = lead + text }
        focused = true
    }

    // MARK: Attachments

    private func attach(fileURL url: URL) {
        do { upload(try AttachmentPrep.prepare(fileURL: url)) } catch { showError(String(describing: error)) }
    }

    private func attach(data: Data, fileName: String, type: UTType) {
        do { upload(try AttachmentPrep.prepare(data: data, fileName: fileName, type: type)) } catch { showError(String(describing: error)) }
    }

    /// Adds the item as uploading and stores it on the host right away, so Send is instant.
    private func upload(_ prepared: AttachmentPrep.Prepared) {
        let item = ComposerAttachment(fileName: prepared.fileName, mimeType: prepared.mimeType, thumbnail: prepared.thumbnail, state: .uploading)
        attachments.append(item)
        Task {
            let state: ComposerAttachment.State
            do {
                state = .ready(try await session.uploadAttachment(prepared.data, fileName: prepared.fileName, mimeType: prepared.mimeType))
            } catch {
                if case HostSessionError.hostError(_, let message) = error { state = .failed(message) } else { state = .failed("Upload failed") }
            }
            if let i = attachments.firstIndex(where: { $0.id == item.id }) { attachments[i].state = state }
        }
    }

    private func accept(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in attach(fileURL: url) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in attach(data: data, fileName: "Image.png", type: .image) }
                }
            }
        }
    }

    #if os(macOS)
    private func pasteImage() {
        guard let data = AttachmentPrep.pasteboardImage() else {
            showError("There is no image on the clipboard.")
            return
        }
        attach(data: data, fileName: "Pasted image.png", type: .png)
    }
    #endif

    private func showError(_ message: String) {
        noteIsError = true
        note = message
    }

    // MARK: Commands

    /// What "/" can do to the conversation itself, rather than say to Pennant.
    private enum Command: String, CaseIterable {
        case clear, compact
        var summary: String {
            switch self {
            case .clear: "Start fresh: nothing said so far reaches Pennant again. It stays on screen; memory and threads stay."
            case .compact: "Fold the conversation so far into a summary, so the model carries less."
            }
        }
        var symbol: String { self == .clear ? "eraser" : "arrow.down.right.and.arrow.up.left" }
    }

    /// "/clear" or "/compact", typed whole.
    private var typedCommand: Command? {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard typed.hasPrefix("/"), attachments.isEmpty else { return nil }
        return Command(rawValue: String(typed.dropFirst()))
    }

    private func run(_ command: Command) {
        text = ""
        suggestionsDismissed = true
        guard isEnabled, let id = conversationID else {
            noteIsError = false
            note = "There's nothing to \(command.rawValue) yet."
            return
        }
        noteIsError = false
        note = command == .clear ? "Clearing…" : "Compacting the conversation…"
        Task {
            do {
                if command == .clear { try await session.startOver(id) } else { _ = try await session.compactConversation(id) }
                note = nil
            } catch {
                noteIsError = true
                note = "Couldn’t \(command.rawValue): \(error)"
            }
        }
    }

    private func ensureSkillsLoaded() {
        guard session.state.skills.isEmpty, session.connection.isConnected else { return }
        Task { try? await session.loadSkills() }
    }

    // MARK: Autocomplete

    /// What follows a "/" typed at the start, while it's the only line.
    private var slashQuery: String? {
        guard text.first == "/", !text.contains("\n") else { return nil }
        return String(text.dropFirst()).trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Commands lead once what's typed starts one; after a bare "/" they come last, so Return there still picks a skill.
    private var suggestions: [ChoiceOption<String>] {
        guard !suggestionsDismissed, let q = slashQuery else { return [] }
        let commands = Command.allCases.filter { q.isEmpty || $0.rawValue.hasPrefix(q) }
            .map { ChoiceOption(Self.commandPrefix + $0.rawValue, title: "/" + $0.rawValue, subtitle: $0.summary, symbol: $0.symbol) }
        let skills = session.state.skills
            .filter { $0.status != .disabled }
            .filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.purpose.lowercased().contains(q) }
            .prefix(6 - commands.count)
            .map { skill in
                let linked = skill.origin == "claude-code"
                let about = [linked ? (skill.needsClaudeCode == nil ? "Claude Code skill" : "Runs in Claude Code") : nil, skill.purpose.isEmpty ? nil : skill.purpose].compactMap { $0 }.joined(separator: " · ")
                return ChoiceOption(skill.id.rawValue, title: skill.name, subtitle: about.isEmpty ? nil : about, symbol: linked ? "terminal" : "wand.and.stars")
            }
        return q.isEmpty ? skills + commands : commands + skills
    }

    private static let commandPrefix = "command:"

    private func move(_ delta: Int) -> KeyPress.Result {
        let items = suggestions
        guard !items.isEmpty else { return .ignored }
        highlighted = (min(highlighted, items.count - 1) + delta + items.count) % items.count
        return .handled
    }

    private func pickHighlighted() -> KeyPress.Result {
        let items = suggestions
        guard !items.isEmpty else { return .ignored }
        pick(items[min(highlighted, items.count - 1)])
        return .handled
    }

    private func pick(_ item: ChoiceOption<String>) {
        if item.id.hasPrefix(Self.commandPrefix), let command = Command(rawValue: String(item.id.dropFirst(Self.commandPrefix.count))) {
            // From a bare "/", a command is only filled in, so a stray Return never clears anything.
            if slashQuery?.isEmpty == true {
                text = "/" + command.rawValue
                focused = true
                return
            }
            return run(command)
        }
        text = "Use the skill \"\(item.title)\": "
        suggestionsDismissed = true
        focused = true
    }
}

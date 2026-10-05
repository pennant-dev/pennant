import PennantCore
import SwiftUI

/// Above the composer while Talk mode is on: what Pennant is doing (listening, with the words as they're heard and a
/// countdown to sending them, thinking or speaking), its voice and how long it waits, a mute for the microphone, a way
/// to send without waiting, and a way to stop.
struct TalkBar: View {
    var talk: TalkSession

    var body: some View {
        HStack(spacing: 10) {
            TalkPulse(phase: talk.phase, muted: talk.isMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text(line)
                    .font(.zoomed(.callout))
                    .foregroundStyle(talk.heard.isEmpty ? PennantTheme.inkSecondary : PennantTheme.ink)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .animation(.easeOut(duration: 0.15), value: line)
                if let seconds = talk.sendingIn {
                    Text("Sending in \(seconds) s. Keep talking to add more.")
                        .font(.zoomed(.caption))
                        .foregroundStyle(PennantTheme.inkTertiary)
                        .contentTransition(.numericText())
                } else if let note = talk.voiceNote {
                    Text(note)
                        .font(.zoomed(.caption))
                        .foregroundStyle(PennantTheme.inkTertiary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                #if os(macOS)
                if NaturalVoice.isSupported { naturalVoices }
                #else
                if !HostVoice.shared.available.isEmpty { hostVoices }
                #endif
                Section("Wait before sending") {
                    ForEach(TalkSession.pauseChoices, id: \.self) { seconds in
                        Button { talk.setPause(seconds) } label: {
                            let name = seconds == 1 ? "1 second of quiet" : "\(seconds.formatted()) seconds of quiet"
                            if seconds == talk.pause { Label(name, systemImage: "checkmark") } else { Text(name) }
                        }
                    }
                }
                Section(systemVoicesTitle) {
                    ForEach(TalkSession.voiceChoices()) { choice in
                        Button { talk.useVoice(choice.id) } label: {
                            if choice.id == talk.voice?.identifier, !usesNaturalVoice { Label(choice.name, systemImage: "checkmark") } else { Text(choice.name) }
                        }
                    }
                }
            } label: {
                Image(systemName: "speaker.wave.2")
            }
            .menuStyle(.button)
            .buttonStyle(IconButtonStyle(size: 28))
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Pennant's voice")
            .accessibilityLabel("Pennant's voice")
            Button { talk.setMuted(!talk.isMuted) } label: {
                Image(systemName: talk.isMuted ? "mic.slash.fill" : "mic")
                    .foregroundStyle(talk.isMuted ? PennantTheme.danger : PennantTheme.ink)
            }
            .buttonStyle(IconButtonStyle(size: 28))
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .help(talk.isMuted ? "Unmute (⇧⌘M)" : "Mute the microphone (⇧⌘M)")
            .accessibilityLabel(talk.isMuted ? "Unmute" : "Mute")
            if !talk.heard.isEmpty, talk.phase != .speaking {
                Button("Send") { talk.sendNow() }
                    .buttonStyle(.pennantPrimaryCompact)
                    .help("Send it now, without waiting for the pause")
            }
            Button("Stop") { talk.stop() }
                .buttonStyle(.pennantCompact)
                .accessibilityLabel("Stop Talk mode")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(PennantTheme.brand.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(PennantTheme.brand.opacity(0.2)))
        .accessibilityElement(children: .combine)
    }

    #if os(macOS)
    /// The natural voices, with what each needs downloading the first time.
    @ViewBuilder private var naturalVoices: some View {
        ForEach(VoiceCatalog.packs) { pack in
            Section(packTitle(pack)) {
                ForEach(VoiceCatalog.voices.filter { $0.pack == pack.id }) { voice in
                    Button { talk.useNaturalVoice(voice.id) } label: { voiceLabel(voice, chosen: NaturalVoice.shared.isOn && NaturalVoice.shared.voiceID == voice.id) }
                }
            }
        }
    }

    private func packTitle(_ pack: VoiceCatalog.Pack) -> String {
        guard !NaturalVoice.shared.downloaded.contains(pack.id) else { return pack.name }
        return "\(pack.name) · \(ByteCountFormatter.string(fromByteCount: pack.size, countStyle: .file)) download"
    }
    #else
    /// The natural voices the host's Mac has, made there and streamed here.
    @ViewBuilder private var hostVoices: some View {
        Section("Your Mac's voices") {
            ForEach(HostVoice.shared.available) { voice in
                Button { talk.useHostVoice(voice.id) } label: { voiceLabel(voice, chosen: HostVoice.shared.voice?.id == voice.id) }
            }
        }
    }
    #endif

    @ViewBuilder private func voiceLabel(_ voice: VoiceCatalog.Voice, chosen: Bool) -> some View {
        let name = "\(voice.name) (\(voice.detail))"
        if chosen { Label(name, systemImage: "checkmark") } else { Text(name) }
    }

    private var usesNaturalVoice: Bool {
        #if os(macOS)
        NaturalVoice.shared.isWanted
        #else
        HostVoice.shared.isWanted
        #endif
    }

    private var systemVoicesTitle: String {
        #if os(macOS)
        "This Mac's voices"
        #else
        "Built-in voices"
        #endif
    }

    private var line: String {
        if let problem = talk.problem, talk.heard.isEmpty { return problem }
        if talk.isMuted, talk.phase != .speaking { return "Muted. Pennant isn't listening; unmute to talk." }
        switch talk.phase {
        case .off, .starting: return "Starting…"
        case .listening: return talk.heard.isEmpty ? "Listening…" : talk.heard
        case .thinking: return talk.heard.isEmpty ? "Thinking…" : talk.heard
        case .speaking: return "Speaking. Talk to interrupt."
        }
    }
}

/// A dot that breathes while listening (grey while muted), spins up while thinking and beats while speaking.
private struct TalkPulse: View {
    var phase: TalkSession.Phase
    var muted: Bool
    @State private var on = false

    var body: some View {
        Circle()
            .fill(phase == .speaking ? PennantTheme.brand : phase == .thinking ? PennantTheme.info : muted ? PennantTheme.inkTertiary : PennantTheme.success)
            .frame(width: 10, height: 10)
            .scaleEffect(on ? 1.35 : 0.85)
            .opacity(on ? 1 : 0.6)
            .animation(.easeInOut(duration: phase == .speaking ? 0.35 : phase == .thinking ? 0.5 : 0.9).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
            .accessibilityHidden(true)
    }
}

import PennantCore
import PennantUI
import SwiftUI

/// Settings › Pennant › Talk mode: the voice Pennant speaks with. A natural voice runs on this Mac's GPU once it's
/// downloaded; the Mac's own voices are there everywhere, and while one downloads.
struct TalkVoiceSettings: View {
    private let natural = NaturalVoice.shared

    var body: some View {
        if NaturalVoice.isSupported {
            Toggle("Speak with a natural voice", isOn: Binding(get: { natural.isOn }, set: { on in
                natural.isOn = on
                if on { natural.prepare() }
            }))
            SettingsNote("A speech model that sounds like a person, run on this Mac's GPU: nothing you say or hear leaves the Mac. It's downloaded the first time it's used. Off, Pennant speaks with the Mac's own voices.")
            if natural.isOn {
                HStack(spacing: 8) {
                    Picker("Voice", selection: Binding(get: { natural.voiceID }, set: { natural.use($0) })) {
                        ForEach(VoiceCatalog.packs) { pack in
                            Section(pack.name) {
                                ForEach(VoiceCatalog.voices.filter { $0.pack == pack.id }) { voice in
                                    Text("\(voice.name) (\(voice.detail))").tag(voice.id)
                                }
                            }
                        }
                    }
                    .fixedSize()
                    Button("Hear it") { natural.sample() }
                        .buttonStyle(.pennantCompact)
                        .disabled(!natural.downloaded.contains(natural.voice.pack))
                    Spacer(minLength: 0)
                }
                ForEach(VoiceCatalog.packs) { pack in packRow(pack) }
                if let error = natural.downloadError { SettingsNote(error, tone: SettingsTone.danger) }
                if case .failed(let message) = natural.helper { SettingsNote(message, tone: SettingsTone.danger) }
            }
        } else {
            SettingsNote("Natural voices need a Mac with Apple silicon. Talk mode speaks with this Mac's own voices: choose one from the speaker menu while you talk.")
        }
    }

    private func packRow(_ pack: VoiceCatalog.Pack) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(pack.name).font(.zoomed(.callout)).foregroundStyle(PennantTheme.ink)
                Text("\(pack.detail) · \(ByteCountFormatter.string(fromByteCount: pack.size, countStyle: .file))")
                    .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkSecondary)
            }
            Spacer(minLength: 8)
            if let progress = natural.progress[pack.id] {
                ProgressView(value: progress).frame(width: 120)
                Button("Stop") { natural.remove(pack.id) }.buttonStyle(.pennantCompact)
            } else if natural.downloaded.contains(pack.id) {
                Text("Downloaded").font(.zoomed(.caption)).foregroundStyle(SettingsTone.success)
                Button("Remove") { natural.remove(pack.id) }.buttonStyle(.pennantCompact)
            } else {
                Button("Download") { natural.download(pack.id) }.buttonStyle(.pennantCompact)
            }
        }
    }
}

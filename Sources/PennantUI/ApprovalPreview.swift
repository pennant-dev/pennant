import PennantCore
import SwiftUI

/// What a card will send, drawn the way it will land: an email with its From, To and subject; a post under the account
/// it goes out as, with the platform's character limit; a message as a bubble; a command as a terminal line. Anything
/// else is the text in a plain box. Read from the card itself (its destination, and the call it makes on approval), so
/// it works for every card a host puts up.
struct ApprovalPreview: View {
    var request: ApprovalRequest
    var text: String
    var markdown: Bool
    var showPlain: Bool
    var textSize: CGFloat?

    var body: some View {
        switch Kind(request) {
        case .email(let email): emailView(email)
        case .post(let post): postView(post)
        case .message(let message): messageView(message)
        case .command(let place): commandView(place)
        case .plain: plainView
        }
    }

    // MARK: Kinds

    enum Kind: Equatable {
        struct Email: Equatable { var from: String?; var to: String?; var cc: String?; var subject: String?; var reply: Bool }
        struct Post: Equatable { var platform: String; var account: String?; var limit: Int?; var color: String }
        struct Message: Equatable { var service: String; var to: String? }
        case email(Email), post(Post), message(Message), command(String), plain

        init(_ r: ApprovalRequest) {
            let tool = (r.action?.tool ?? r.heldCall?.name ?? "").lowercased()
            let args = r.action?.arguments ?? r.heldCall?.arguments ?? .null
            let parts = r.destination.components(separatedBy: " · ")
            let lead = (parts.first ?? "").trimmingCharacters(in: .whitespaces)
            let leadWord = lead.lowercased()
            let account = parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : nil

            if tool == "shell" || leadWord == "shell" || r.action?.textField == "command" {
                self = .command(leadWord == "shell" || lead.isEmpty ? "This Mac" : lead)
                return
            }
            if tool.contains("mail_send") || tool.contains("mail_reply") || tool.contains("send_email") || ["outlook", "gmail", "email", "mail"].contains(where: { leadWord.hasPrefix($0) }) {
                let d = r.destination
                func list(_ v: JSONValue?) -> String? {
                    if let a = v?.arrayValue { let s = a.compactMap { $0.stringValue ?? $0["address"]?.stringValue }.joined(separator: ", "); return s.isEmpty ? nil : s }
                    return v?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                }
                let from = Self.match(#"from ([^\s,()]+@[^\s,()]+)"#, in: d) ?? Self.match(#"^(?:Outlook · |Email · )?([^\s,()]+@[^\s,()]+) →"#, in: d)
                let to = list(args["to"]) ?? Self.match(#"(?:\bto|→) (.+?)(?: \(|$)"#, in: d)
                let reply = tool.contains("reply") || d.lowercased().contains("reply")
                self = .email(.init(from: from, to: to, cc: list(args["cc"]), subject: args["subject"]?.stringValue ?? r.headline, reply: reply))
                return
            }
            if let platform = Self.platforms.first(where: { leadWord == $0.key || leadWord.hasPrefix($0.key + " ") }) {
                self = .post(.init(platform: platform.value.name, account: account, limit: platform.value.limit, color: platform.value.color))
                return
            }
            if let service = Self.messengers.first(where: { leadWord.hasPrefix($0.lowercased()) }) {
                self = .message(.init(service: service, to: account))
                return
            }
            self = .plain
        }

        static let platforms: [String: (name: String, limit: Int?, color: String)] = [
            "linkedin": ("LinkedIn", 3000, "#0A66C2"), "x": ("X", 280, "#111111"), "twitter": ("X", 280, "#111111"),
            "reddit": ("Reddit", nil, "#FF4500"), "youtube": ("YouTube", nil, "#E62117"), "bluesky": ("Bluesky", 300, "#1185FE"),
            "threads": ("Threads", 500, "#111111"), "facebook": ("Facebook", nil, "#1877F2"), "instagram": ("Instagram", 2200, "#D62976"),
            "mastodon": ("Mastodon", 500, "#6364FF"),
        ]
        static let messengers = ["iMessage", "SMS", "WhatsApp", "Signal", "Telegram", "Teams", "Slack"]

        static func match(_ pattern: String, in text: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  m.numberOfRanges > 1, let range = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[range]).trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: Pieces

    @ViewBuilder private var words: some View {
        if markdown, !showPlain {
            PennantMarkdown(text, size: textSize)
        } else {
            Text(text)
                .font(.zoomed(.callout))
                .foregroundStyle(PennantTheme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var plainView: some View {
        words
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PennantTheme.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func framed<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PennantTheme.windowBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PennantTheme.border))
    }

    private func emailView(_ e: Kind.Email) -> some View {
        framed {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(e.subject ?? (e.reply ? "Reply" : "No subject"))
                        .font(.zoomed(.headline))
                        .foregroundStyle(e.subject == nil ? PennantTheme.inkSecondary : PennantTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if e.reply { Chip("Reply") }
                }
                VStack(alignment: .leading, spacing: 4) {
                    if let from = e.from { addressRow("From", from, avatar: true) }
                    if let to = e.to { addressRow("To", to) }
                    if let cc = e.cc { addressRow("Cc", cc) }
                }
            }
            .padding(14)
            Divider().overlay(PennantTheme.divider)
            words.padding(14)
        }
    }

    private func addressRow(_ label: String, _ value: String, avatar: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary).frame(width: 34, alignment: .leading)
            if avatar {
                Text(String(value.prefix(1)).uppercased())
                    .font(.zoomed(size: 10, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 18, height: 18).background(PennantTheme.brand, in: Circle())
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
            }
            Text(value).font(.zoomed(.callout)).foregroundStyle(PennantTheme.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func postView(_ p: Kind.Post) -> some View {
        let color = Color(hex: p.color)
        return framed {
            HStack(spacing: 10) {
                Text(String(p.platform.prefix(1)))
                    .font(.zoomed(size: 15, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 32, height: 32).background(color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.account ?? p.platform).font(.zoomed(.callout).weight(.semibold)).foregroundStyle(PennantTheme.ink).lineLimit(1)
                    Text("Post on \(p.platform)").font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding([.horizontal, .top], 14)
            words.padding(14)
            if let limit = p.limit {
                let over = text.count > limit
                Text("\(text.count) of \(limit) characters")
                    .font(.zoomed(.caption2).monospacedDigit())
                    .foregroundStyle(over ? PennantTheme.danger : PennantTheme.inkTertiary)
                    .padding([.horizontal, .bottom], 14)
            }
        }
    }

    private func messageView(_ m: Kind.Message) -> some View {
        framed {
            Text("\(m.service)\(m.to.map { " to \($0)" } ?? "")")
                .font(.zoomed(.caption)).foregroundStyle(PennantTheme.inkTertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
            HStack {
                Spacer(minLength: 60)
                Text(text)
                    .font(.zoomed(.callout))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(m.service == "iMessage" ? Color(hex: "#0B84FF") : PennantTheme.brand, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .padding(14)
        }
    }

    private func commandView(_ place: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: "#FF5F57")).frame(width: 9, height: 9)
                Circle().fill(Color(hex: "#FEBC2E")).frame(width: 9, height: 9)
                Circle().fill(Color(hex: "#28C840")).frame(width: 9, height: 9)
                Text("Runs on \(place)").font(.zoomed(.caption)).foregroundStyle(Color.white.opacity(0.55)).padding(.leading, 6).lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("$").foregroundStyle(Color(hex: "#7EE787"))
                Text(text).foregroundStyle(Color.white.opacity(0.92)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .font(.zoomed(size: 12.5, design: .monospaced))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "#16161A"), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
    }
}

import Foundation
import PennantCore

/// Talk mode reads short replies out as they are. A long one, or news from the work, is said the way a person would
/// tell it: the gist in a sentence or two, without the links, code and numbers that are for the screen.
extension TaskRuntime {
    static let spokenVersionRules = """
    Say what this message tells them in one or two short sentences, the way you'd tell them in person: what happened, \
    and anything they need to do or decide. Leave out links, code, file names, line numbers, IDs and other details \
    they can read on screen. Don't repeat what you've already said aloud. Reply with only the words to say.
    """

    /// `text` as Pennant would say it aloud, carrying on from `alreadySaid`; nil when no model answers in time (the app
    /// then reads it out as it is).
    func spokenVersion(of text: String, alreadySaid: String) async -> String? {
        guard let lead = await leadAgent() else { return nil }
        var system = "You are \(lead.name), the owner's assistant, talking with them out loud.\n"
        if !lead.style.isEmpty { system += "Voice and manner: \(lead.style)\n" }
        system += "\n" + Self.spokenVersionRules
        let said = alreadySaid.trimmingCharacters(in: .whitespacesAndNewlines)
        let ask = (said.isEmpty ? "" : "You've already said aloud: “\(said)”\n\n") + "Your message in the chat:\n\(text)\n\nWhat you say out loud:"
        for choice in await modelChoices(for: lead) {
            let request = InferenceRequest(messages: [.system(system), .user(ask)], maxOutputTokens: 300, temperature: 0.3, disableTools: true,
                                           reasoningEffort: Self.chatEffort(agent: lead, model: choice))
            guard let reply = try? await withTimeout(seconds: 15, { try await choice.provider.complete(request).text }) else { continue }
            let words = reply.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”")))
            if !words.isEmpty { return words }
        }
        return nil
    }
}

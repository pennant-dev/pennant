import Foundation

/// An OpenAI-compatible endpoint the `openai` provider can be pointed at with one pick: the base URL, where the key
/// comes from, and what the vendor's documentation says the endpoint supports. Data only; the host reads nothing
/// here. Entries follow each provider's documentation as of September 2026. `verified` is true when the vendor's
/// documentation or a live probe confirmed the base URL; anything else is a hypothesis to test.
public struct InferencePreset: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var publisher: String
    /// Without a trailing slash: the host appends `/chat/completions` and `/models` itself.
    public var baseURL: String
    /// Where to create an API key; nil for local servers that take none.
    public var keyHelpURL: String?
    public var docsURL: String?
    /// Whether the endpoint answers `GET /models`. When it does not, `exampleModels` stand in for the list.
    public var supportsModelsEndpoint: Bool
    /// Defaults for the vision and tools toggles when the preset is picked; the user can still flip them.
    public var supportsVision: Bool
    public var supportsTools: Bool
    /// Current model ids from the vendor's docs, offered in the model menu next to what the endpoint lists.
    public var exampleModels: [String]
    /// Quirks worth reading before the first request (clamped temperature, prompted JSON mode, billing).
    public var notes: String?
    /// True when the base URL was confirmed against the publisher's documentation or a live probe.
    public var verified: Bool
    /// False for local servers, where the key field is optional and no key link is shown.
    public var needsKey: Bool
    /// SF Symbol for the picker row.
    public var symbol: String

    public init(id: String, name: String, publisher: String, baseURL: String, keyHelpURL: String? = nil, docsURL: String? = nil, supportsModelsEndpoint: Bool = true, supportsVision: Bool = true, supportsTools: Bool = true, exampleModels: [String] = [], notes: String? = nil, verified: Bool = false, needsKey: Bool = true, symbol: String = "cloud") {
        self.id = id
        self.name = name
        self.publisher = publisher
        self.baseURL = baseURL
        self.keyHelpURL = keyHelpURL
        self.docsURL = docsURL
        self.supportsModelsEndpoint = supportsModelsEndpoint
        self.supportsVision = supportsVision
        self.supportsTools = supportsTools
        self.exampleModels = exampleModels
        self.notes = notes
        self.verified = verified
        self.needsKey = needsKey
        self.symbol = symbol
    }
}

/// The preset catalogue: hosted API-key vendors first, then the local servers Pennant has always offered.
public enum InferencePresets {
    public static let all: [InferencePreset] = [
        // MARK: Hosted, key in `Authorization: Bearer`

        InferencePreset(
            id: "openai", name: "OpenAI", publisher: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            keyHelpURL: "https://platform.openai.com/api-keys",
            docsURL: "https://platform.openai.com/docs/api-reference",
            exampleModels: ["gpt-5.5", "gpt-5-mini"],
            verified: true
        ),
        InferencePreset(
            id: "anthropic", name: "Anthropic", publisher: "Anthropic",
            baseURL: "https://api.anthropic.com/v1",
            keyHelpURL: "https://platform.claude.com/settings/keys",
            docsURL: "https://platform.claude.com/docs/en/cli-sdks-libraries/libraries/openai-sdk",
            exampleModels: ["claude-opus-5", "claude-sonnet-4-6"],
            notes: "Anthropic's OpenAI-compatible layer: temperature is capped at 1, JSON mode is asked for in the prompt (response_format is ignored), and system messages are hoisted and concatenated. Anthropic calls it a test-and-compare aid rather than a production path.",
            verified: true
        ),
        InferencePreset(
            id: "google-ai-studio", name: "Google AI Studio", publisher: "Google",
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
            keyHelpURL: "https://aistudio.google.com/apikey",
            docsURL: "https://ai.google.dev/gemini-api/docs/openai",
            exampleModels: ["gemini-3.8-flash", "gemini-2.5-pro"],
            notes: "Gemini through the AI Studio key. Free-tier keys run out within a few agent turns; a paid key follows AI Studio pricing.",
            verified: true
        ),
        InferencePreset(
            id: "xai", name: "xAI", publisher: "xAI",
            baseURL: "https://api.x.ai/v1",
            keyHelpURL: "https://console.x.ai",
            docsURL: "https://docs.x.ai/docs/overview",
            exampleModels: ["grok-4.7", "grok-4.6"],
            notes: "Images as JPEG or PNG up to 20 MiB.",
            verified: true
        ),
        InferencePreset(
            id: "mistral", name: "Mistral", publisher: "Mistral AI",
            baseURL: "https://api.mistral.ai/v1",
            keyHelpURL: "https://console.mistral.ai/api-keys",
            docsURL: "https://docs.mistral.ai/api/",
            exampleModels: ["mistral-medium-latest", "mistral-large-latest"],
            notes: "Vision on the medium, large, small and ministral models from 2025 on; older ids are text only.",
            verified: true
        ),
        InferencePreset(
            id: "deepseek", name: "DeepSeek", publisher: "DeepSeek",
            baseURL: "https://api.deepseek.com",
            keyHelpURL: "https://platform.deepseek.com/api_keys",
            docsURL: "https://api-docs.deepseek.com/",
            exampleModels: ["deepseek-flash", "deepseek-v4-pro"],
            notes: "Vision on deepseek-flash. The legacy ids deepseek-v4-flash and deepseek-v4-flash-vision-exp still answer and route to Flash.",
            verified: true
        ),
        InferencePreset(
            id: "moonshot", name: "Moonshot Kimi", publisher: "Moonshot AI",
            baseURL: "https://api.moonshot.ai/v1",
            keyHelpURL: "https://platform.kimi.ai",
            docsURL: "https://platform.kimi.ai/docs/guide/start-using-kimi-api",
            exampleModels: ["kimi-k3", "kimi-k2.7-code-highspeed"],
            notes: "The platform API (pay as you go). Accounts in China use https://api.moonshot.cn/v1 instead.",
            verified: true
        ),
        InferencePreset(
            id: "kimi-code", name: "Kimi Code", publisher: "Moonshot AI",
            baseURL: "https://api.kimi.com/coding/v1",
            keyHelpURL: "https://www.kimi.com/code",
            docsURL: "https://www.kimi.com/code/docs/en/",
            exampleModels: ["k3", "k3-256k", "kimi-for-coding", "kimi-for-coding-highspeed"],
            notes: "The coding plan's subscription endpoint. Its terms tie the key to named tools; Pennant identifies itself and reports a refusal rather than posing as another client. Overseas accounts use https://api.kimi.ai/coding/v1.",
            verified: true
        ),
        InferencePreset(
            id: "zai", name: "Z.ai GLM", publisher: "Z.ai",
            baseURL: "https://api.z.ai/api/paas/v4",
            keyHelpURL: "https://z.ai/manage-apikey/apikey-list",
            docsURL: "https://docs.z.ai/guides/overview/quick-start",
            supportsVision: false,
            exampleModels: ["glm-5.3", "glm-5.3-flash"],
            notes: "The general API. Vision on glm-4.6v and glm-5.3-flash only. Accounts in China use https://open.bigmodel.cn/api/paas/v4.",
            verified: true
        ),
        InferencePreset(
            id: "zai-coding", name: "Z.ai GLM Coding Plan", publisher: "Z.ai",
            baseURL: "https://api.z.ai/api/coding/paas/v4",
            keyHelpURL: "https://z.ai/manage-apikey/apikey-list",
            docsURL: "https://docs.z.ai/devpack/overview",
            supportsVision: false,
            exampleModels: ["glm-5.3", "glm-5.3-flash"],
            notes: "The coding plan's endpoint, billed separately from the general API: an \"Insufficient balance\" error usually means the key belongs to the other one. Credits per five hours: Lite 2,000, Pro 12,000, Max 28,000. Vision on glm-5.3-flash only.",
            verified: true
        ),
        InferencePreset(
            id: "alibaba-coding", name: "Alibaba Cloud Coding Plan", publisher: "Alibaba Cloud",
            baseURL: "https://coding-intl.dashscope.aliyuncs.com/v1",
            keyHelpURL: "https://www.alibabacloud.com/help/en/model-studio/coding-plan",
            docsURL: "https://www.alibabacloud.com/help/en/model-studio/coding-plan",
            exampleModels: ["qwen3.7-plus", "qwen3-coder-plus"],
            notes: "Qwen through the Model Studio coding plan; the endpoint also lists GLM, Kimi and MiniMax models. Vision on qwen3.6-plus and qwen3.7-plus. Accounts in China use https://coding.dashscope.aliyuncs.com/v1.",
            verified: true
        ),
        InferencePreset(
            id: "alibaba-model-studio", name: "Alibaba Model Studio", publisher: "Alibaba Cloud",
            baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
            keyHelpURL: "https://modelstudio.console.alibabacloud.com/?tab=model#/api-key",
            docsURL: "https://www.alibabacloud.com/help/en/model-studio/compatibility-of-openai-with-dashscope",
            exampleModels: ["qwen3.8-max", "qwen3.7-plus"],
            notes: "The pay-as-you-go DashScope route (the Qwen Code sign-in no longer serves individuals). Whether it lists models is unconfirmed; type the id if the list stays empty. Accounts in China use https://dashscope.aliyuncs.com/compatible-mode/v1.",
            verified: false
        ),
        InferencePreset(
            id: "openrouter", name: "OpenRouter", publisher: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1",
            keyHelpURL: "https://openrouter.ai/settings/keys",
            docsURL: "https://openrouter.ai/docs/api-reference/overview",
            exampleModels: ["openai/gpt-5.5", "qwen/qwen3.7-max"],
            notes: "One key for many vendors; vision and tool support vary per model, so check the model page before turning the toggles on.",
            verified: true
        ),
        InferencePreset(
            id: "groq", name: "Groq", publisher: "Groq",
            baseURL: "https://api.groq.com/openai/v1",
            keyHelpURL: "https://console.groq.com/keys",
            docsURL: "https://console.groq.com/docs/openai",
            supportsVision: false,
            exampleModels: ["openai/gpt-oss-120b", "llama-3.3-70b-versatile"],
            notes: "Vision on a few models only. Rejects logprobs, logit_bias, top_logprobs and messages[].name; n must be 1.",
            verified: true
        ),
        InferencePreset(
            id: "together", name: "Together", publisher: "Together AI",
            baseURL: "https://api.together.ai/v1",
            keyHelpURL: "https://api.together.ai/settings/api-keys",
            docsURL: "https://docs.together.ai/docs/openai-api-compatibility",
            exampleModels: ["MiniMaxAI/MiniMax-M3", "deepseek-ai/DeepSeek-V4.1-Flash"],
            verified: true
        ),
        InferencePreset(
            id: "fireworks", name: "Fireworks", publisher: "Fireworks AI",
            baseURL: "https://api.fireworks.ai/inference/v1",
            keyHelpURL: "https://app.fireworks.ai/settings/users/api-keys",
            docsURL: "https://docs.fireworks.ai/tools-sdks/openai-compatibility",
            exampleModels: ["accounts/fireworks/routers/kimi-latest", "accounts/fireworks/models/deepseek-v3p1"],
            notes: "max_tokens is silently clamped to the model's window.",
            verified: true
        ),
        InferencePreset(
            id: "perplexity", name: "Perplexity", publisher: "Perplexity",
            baseURL: "https://api.perplexity.ai/router/v1",
            keyHelpURL: "https://console.perplexity.ai",
            docsURL: "https://docs.perplexity.ai/docs/router/quickstart",
            supportsVision: false,
            exampleModels: ["perplexity/kimi-k3"],
            notes: "The Router API only: Sonar chat completions at api.perplexity.ai end on 2026-09-27 and the Agent API is not chat-completions shaped. Image and tool support are unconfirmed; JSON mode is asked for in the prompt.",
            verified: true
        ),
        InferencePreset(
            id: "ollama-cloud", name: "Ollama Cloud", publisher: "Ollama",
            baseURL: "https://ollama.com/v1",
            keyHelpURL: "https://ollama.com/settings/keys",
            docsURL: "https://docs.ollama.com/cloud",
            exampleModels: ["kimi-k3", "glm-5.3", "deepseek-v4.1-flash", "gpt-oss:120b"],
            notes: "API names differ from the app's (gemma4:31b, not gemma4:cloud). Images go as data URIs, which is what Pennant sends.",
            verified: true
        ),

        // MARK: Local and private servers, no key

        InferencePreset(
            id: "ollama", name: "Ollama on this Mac", publisher: "Ollama",
            baseURL: "http://localhost:11434/v1",
            docsURL: "https://docs.ollama.com/api/openai-compatibility",
            exampleModels: ["gemma4:e2b-it-qat"],
            verified: true, needsKey: false, symbol: "desktopcomputer"
        ),
        InferencePreset(
            id: "lm-studio", name: "LM Studio", publisher: "LM Studio",
            baseURL: "http://localhost:1234/v1",
            docsURL: "https://lmstudio.ai/docs/app/api/endpoints/openai",
            verified: true, needsKey: false, symbol: "desktopcomputer"
        ),
        InferencePreset(
            id: "vllm", name: "vLLM on this Mac", publisher: "vLLM",
            baseURL: "http://localhost:8000/v1",
            docsURL: "https://docs.vllm.ai/en/latest/serving/openai_compatible_server.html",
            verified: true, needsKey: false, symbol: "desktopcomputer"
        ),
    ]

    public static func preset(id: String) -> InferencePreset? {
        all.first { $0.id == id }
    }

    /// The preset whose base URL the given one starts with, so `https://api.deepseek.com/v1` and a trailing slash
    /// still read as DeepSeek. Scheme and host compare case-insensitively; the longest matching base wins; a
    /// different path segment (`/v1beta` against `/v1`) is no match.
    public static func preset(for baseURL: String) -> InferencePreset? {
        let candidate = normalized(baseURL)
        guard !candidate.isEmpty else { return nil }
        return all
            .filter { p in
                let base = normalized(p.baseURL)
                return candidate == base || candidate.hasPrefix(base + "/")
            }
            .max { normalized($0.baseURL).count < normalized($1.baseURL).count }
    }

    private static func normalized(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

import Foundation

/// Servers Pennant can connect to with one click. Entries are checked against the publisher's documentation when
/// written; anything that could not be confirmed on an official page stays `verified: false` with a docs link.
public enum MCPCatalog {
    /// Entra v2 endpoints for a tenant (`{tenant}`: a tenant ID, `organizations`, or `common`); a public client with
    /// PKCE and a `localhost` redirect (Entra matches localhost redirects on host and path, any port).
    static let microsoftOAuth = OAuthServerConfig(
        authorizeURL: "https://login.microsoftonline.com/{tenant}/oauth2/v2.0/authorize",
        tokenURL: "https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token",
        extraAuthorizeParameters: ["prompt": "select_account"],
        redirectHost: "localhost"
    )

    /// Delegated Graph permissions the Microsoft 365 connector asks for. ChannelMessage.Read.All needs admin consent.
    public static let microsoftGraphScopes = [
        "offline_access", "User.Read", "Mail.ReadWrite", "Mail.Send", "Calendars.ReadWrite",
        "Chat.ReadWrite", "ChatMessage.Send", "ChannelMessage.Send", "ChannelMessage.Read.All",
        "Team.ReadBasic.All", "Channel.ReadBasic.All", "Files.ReadWrite.All", "Sites.Read.All",
    ]

    /// The fixed category set, in the order the marketplace shows it.
    public static let categories = ["Developer", "Productivity", "Business", "Social", "Design", "Data", "Web", "Local"]

    public static let entries: [MCPCatalogEntry] = [
        // MARK: Developer

        // GitHub's authorization server (github.com/login/oauth) advertises no registration endpoint, so OAuth needs
        // an OAuth App of your own (github.com/settings/developers) with the host's fixed redirect URL; a token is
        // the one-step route.
        MCPCatalogEntry(
            id: "github", name: "GitHub", publisher: "GitHub",
            summary: "Issues, pull requests, and code search across your repositories, with a personal access token or your own OAuth app.",
            category: "Developer", symbol: "chevron.left.forwardslash.chevron.right",
            url: "https://api.githubcopilot.com/mcp/",
            auth: .bearerKey,
            keyHelpURL: "https://github.com/settings/personal-access-tokens/new",
            docsURL: "https://docs.github.com/en/copilot/how-tos/provide-context/use-mcp/set-up-the-github-mcp-server",
            verified: true,
            brandIcon: "github", brandColor: "#181717",
            alternateAuth: .oauthDefault, needsRegisteredClient: true
        ),
        MCPCatalogEntry(
            id: "linear", name: "Linear", publisher: "Linear",
            summary: "Create and update issues, projects, and cycles in your Linear workspace.",
            category: "Developer", symbol: "checklist",
            url: "https://mcp.linear.app/mcp",
            auth: .oauthDefault,
            docsURL: "https://linear.app/docs/mcp",
            verified: true,
            brandIcon: "linear", brandColor: "#5E6AD2"
        ),
        MCPCatalogEntry(
            id: "sentry", name: "Sentry", publisher: "Sentry",
            summary: "Look up errors, traces, and releases, and let agents work through what broke.",
            category: "Developer", symbol: "exclamationmark.triangle",
            url: "https://mcp.sentry.dev/mcp",
            auth: .oauthDefault,
            docsURL: "https://mcp.sentry.dev/",
            verified: true,
            brandIcon: "sentry", brandColor: "#362D59"
        ),
        MCPCatalogEntry(
            id: "cloudflare-workers", name: "Cloudflare Workers", publisher: "Cloudflare",
            summary: "Manage Workers, KV, R2, D1, and the other bindings in your Cloudflare account.",
            category: "Developer", symbol: "cloud",
            url: "https://bindings.mcp.cloudflare.com/mcp",
            auth: .oauthDefault,
            docsURL: "https://developers.cloudflare.com/agents/model-context-protocol/cloudflare/servers-for-cloudflare/",
            verified: true,
            brandIcon: "cloudflareworkers", brandColor: "#F38020"
        ),
        MCPCatalogEntry(
            id: "context7", name: "Context7", publisher: "Upstash",
            summary: "Version-specific docs for libraries and frameworks, pulled in while agents write code.",
            category: "Developer", symbol: "book",
            url: "https://mcp.context7.com/mcp",
            auth: .bearerKey,
            keyHelpURL: "https://context7.com/dashboard",
            docsURL: "https://github.com/upstash/context7",
            verified: true
        ),
        MCPCatalogEntry(
            id: "deepwiki", name: "DeepWiki", publisher: "Cognition",
            summary: "Ask questions about any public GitHub repository and read its generated docs.",
            category: "Developer", symbol: "text.book.closed",
            url: "https://mcp.deepwiki.com/mcp",
            auth: .none,
            docsURL: "https://docs.devin.ai/work-with-devin/deepwiki-mcp",
            verified: true
        ),

        // MARK: Productivity

        MCPCatalogEntry(
            id: "notion", name: "Notion", publisher: "Notion",
            summary: "Search, read, and edit the pages and databases in your Notion workspace.",
            category: "Productivity", symbol: "doc.text",
            url: "https://mcp.notion.com/mcp",
            auth: .oauthDefault,
            docsURL: "https://developers.notion.com/docs/get-started-with-mcp",
            verified: true,
            brandIcon: "notion", brandColor: "#000000"
        ),
        MCPCatalogEntry(
            id: "atlassian", name: "Jira & Confluence", publisher: "Atlassian",
            summary: "Work with Jira issues and Confluence pages in your Atlassian cloud site.",
            category: "Productivity", symbol: "rectangle.3.group",
            url: "https://mcp.atlassian.com/v2/mcp",
            auth: .oauthDefault,
            docsURL: "https://support.atlassian.com/atlassian-rovo-mcp-server/docs/getting-started-with-the-atlassian-remote-mcp-server/",
            verified: true,
            brandIcon: "atlassian", brandColor: "#0052CC"
        ),
        MCPCatalogEntry(
            id: "asana", name: "Asana", publisher: "Asana",
            summary: "Tasks, projects, and goals from your Asana workspace, readable and editable by agents.",
            category: "Productivity", symbol: "checkmark.circle",
            url: "https://mcp.asana.com/v2/mcp",
            auth: .oauthDefault,
            docsURL: "https://developers.asana.com/docs/using-asanas-model-control-protocol-mcp-server",
            verified: true,
            brandIcon: "asana", brandColor: "#F06A6A"
        ),
        MCPCatalogEntry(
            id: "monday", name: "monday.com", publisher: "monday.com",
            summary: "Boards, items, and updates from your monday.com account.",
            category: "Productivity", symbol: "tablecells",
            url: "https://mcp.monday.com/mcp",
            auth: .oauthDefault,
            docsURL: "https://developer.monday.com/api-reference/docs/integrate-with-monday-mcp",
            verified: true
        ),
        MCPCatalogEntry(
            id: "zapier", name: "Zapier", publisher: "Zapier",
            summary: "Run actions in the apps Zapier connects to, chosen per server in your Zapier account.",
            category: "Productivity", symbol: "bolt",
            url: "https://mcp.zapier.com/api/v1/connect",
            auth: .oauthDefault,
            docsURL: "https://docs.zapier.com/mcp/get-started/connect",
            verified: true,
            brandIcon: "zapier", brandColor: "#FF4F00"
        ),

        // Microsoft 365 through Microsoft Graph, built into Pennant: the user's own Entra app (a public client, no
        // secret) and delegated permissions. Works without a Copilot licence; Teams APIs need a work account.
        MCPCatalogEntry(
            id: "microsoft365", name: "Microsoft 365", publisher: "Microsoft",
            summary: "Outlook mail and calendar, Teams chats and channels, and OneDrive and SharePoint files through Microsoft Graph with your own sign-in; no Copilot licence needed.",
            category: "Productivity", symbol: "square.grid.2x2",
            auth: .oauth(scopes: MCPCatalog.microsoftGraphScopes, clientID: nil, clientSecret: nil),
            parameters: [.init(key: "tenant", label: "Directory (tenant) ID", placeholder: "Your tenant ID, or organizations")],
            docsURL: "https://learn.microsoft.com/en-us/graph/auth-register-app-v2",
            verified: true,
            brandColor: "#0078D4",
            needsRegisteredClient: true,
            builtin: "microsoft365",
            oauthServer: microsoftOAuth,
            setupSteps: [
                "In the Microsoft Entra admin center (entra.microsoft.com), open App registrations and choose New registration. Name it Pennant and keep \"Accounts in this organizational directory only\".",
                "Under Authentication, add a platform: Mobile and desktop applications, with the redirect URL below.",
                "Under API permissions, add Microsoft Graph delegated permissions: User.Read, offline_access, Mail.ReadWrite, Mail.Send, Calendars.ReadWrite, Chat.ReadWrite, ChatMessage.Send, ChannelMessage.Send, ChannelMessage.Read.All, Team.ReadBasic.All, Channel.ReadBasic.All, Files.ReadWrite.All and Sites.Read.All. Then choose Grant admin consent.",
                "Copy the Application (client) ID and the Directory (tenant) ID into the fields here. The app needs no client secret.",
            ],
            needsClientSecret: false
        ),
        // Microsoft's own remote MCP servers (Work IQ, Agent 365 tooling). Each needs a Microsoft 365 Copilot licence
        // and a tenant GUID; the audience is the server URL itself, requested as `<url>/.default`.
        MCPCatalogEntry(
            id: "workiq-mail", name: "Work IQ Mail", publisher: "Microsoft",
            summary: "Microsoft's Outlook mail server: read, search, draft, send and reply to mail (needs a Microsoft 365 Copilot licence).",
            category: "Productivity", symbol: "envelope",
            url: "https://agent365.svc.cloud.microsoft/agents/tenants/{tenant}/servers/mcp_MailTools",
            auth: .oauth(scopes: ["https://agent365.svc.cloud.microsoft/agents/tenants/{tenant}/servers/mcp_MailTools/.default", "offline_access", "openid", "profile"], clientID: nil, clientSecret: nil),
            parameters: [.init(key: "tenant", label: "Directory (tenant) ID", placeholder: "00000000-0000-0000-0000-000000000000")],
            docsURL: "https://learn.microsoft.com/en-us/microsoft-agent-365/tooling-servers-overview",
            verified: true,
            brandColor: "#0078D4",
            needsRegisteredClient: true,
            oauthServer: microsoftOAuth,
            setupSteps: [
                "Work IQ servers need a Microsoft 365 Copilot licence and are in preview. An admin can allow or block them under Agents › Tools in the Microsoft 365 admin center.",
                "In the Microsoft Entra admin center, open App registrations and choose New registration (or reuse the Pennant app). Under Authentication, add Mobile and desktop applications with the redirect URL below.",
                "Under API permissions › APIs my organization uses, find Work IQ and add the WorkIQ-MailServer permission. Grant admin consent.",
                "Copy the Application (client) ID and the Directory (tenant) ID (a GUID) into the fields here. No client secret.",
            ],
            needsClientSecret: false
        ),
        MCPCatalogEntry(
            id: "workiq-calendar", name: "Work IQ Calendar", publisher: "Microsoft",
            summary: "Microsoft's calendar server: list, create, update and answer events and resolve conflicts (needs a Microsoft 365 Copilot licence).",
            category: "Productivity", symbol: "calendar",
            url: "https://agent365.svc.cloud.microsoft/agents/tenants/{tenant}/servers/mcp_CalendarTools",
            auth: .oauth(scopes: ["https://agent365.svc.cloud.microsoft/agents/tenants/{tenant}/servers/mcp_CalendarTools/.default", "offline_access", "openid", "profile"], clientID: nil, clientSecret: nil),
            parameters: [.init(key: "tenant", label: "Directory (tenant) ID", placeholder: "00000000-0000-0000-0000-000000000000")],
            docsURL: "https://learn.microsoft.com/en-us/microsoft-agent-365/tooling-servers-overview",
            verified: true,
            brandColor: "#0078D4",
            needsRegisteredClient: true,
            oauthServer: microsoftOAuth,
            setupSteps: [
                "Work IQ servers need a Microsoft 365 Copilot licence and are in preview. An admin can allow or block them under Agents › Tools in the Microsoft 365 admin center.",
                "In the Microsoft Entra admin center, open App registrations and choose New registration (or reuse the Pennant app). Under Authentication, add Mobile and desktop applications with the redirect URL below.",
                "Under API permissions › APIs my organization uses, find Work IQ and add the WorkIQ-CalendarServer permission. Grant admin consent.",
                "Copy the Application (client) ID and the Directory (tenant) ID (a GUID) into the fields here. No client secret.",
            ],
            needsClientSecret: false
        ),
        MCPCatalogEntry(
            id: "workiq-teams", name: "Work IQ Teams", publisher: "Microsoft",
            summary: "Microsoft's Teams server: chats, channel posts and members (needs a Microsoft 365 Copilot licence).",
            category: "Productivity", symbol: "bubble.left.and.bubble.right",
            url: "https://agent365.svc.cloud.microsoft/agents/tenants/{tenant}/servers/mcp_TeamsServer",
            auth: .oauth(scopes: ["https://agent365.svc.cloud.microsoft/agents/tenants/{tenant}/servers/mcp_TeamsServer/.default", "offline_access", "openid", "profile"], clientID: nil, clientSecret: nil),
            parameters: [.init(key: "tenant", label: "Directory (tenant) ID", placeholder: "00000000-0000-0000-0000-000000000000")],
            docsURL: "https://learn.microsoft.com/en-us/microsoft-agent-365/tooling-servers-overview",
            verified: true,
            brandColor: "#0078D4",
            needsRegisteredClient: true,
            oauthServer: microsoftOAuth,
            setupSteps: [
                "Work IQ servers need a Microsoft 365 Copilot licence and are in preview. An admin can allow or block them under Agents › Tools in the Microsoft 365 admin center.",
                "In the Microsoft Entra admin center, open App registrations and choose New registration (or reuse the Pennant app). Under Authentication, add Mobile and desktop applications with the redirect URL below.",
                "Under API permissions › APIs my organization uses, find Work IQ and add the WorkIQ-TeamsServer permission. Grant admin consent.",
                "Copy the Application (client) ID and the Directory (tenant) ID (a GUID) into the fields here. No client secret.",
            ],
            needsClientSecret: false
        ),
        MCPCatalogEntry(
            id: "workiq-sharepoint", name: "Work IQ SharePoint", publisher: "Microsoft",
            summary: "Microsoft's SharePoint server: sites, files, lists and search (needs a Microsoft 365 Copilot licence).",
            category: "Productivity", symbol: "folder",
            url: "https://agent365.svc.cloud.microsoft/agents/tenants/{tenant}/servers/mcp_SharePointRemoteServer",
            auth: .oauth(scopes: ["https://agent365.svc.cloud.microsoft/agents/tenants/{tenant}/servers/mcp_SharePointRemoteServer/.default", "offline_access", "openid", "profile"], clientID: nil, clientSecret: nil),
            parameters: [.init(key: "tenant", label: "Directory (tenant) ID", placeholder: "00000000-0000-0000-0000-000000000000")],
            docsURL: "https://learn.microsoft.com/en-us/microsoft-agent-365/tooling-servers-overview",
            verified: true,
            brandColor: "#0078D4",
            needsRegisteredClient: true,
            oauthServer: microsoftOAuth,
            setupSteps: [
                "Work IQ servers need a Microsoft 365 Copilot licence and are in preview. An admin can allow or block them under Agents › Tools in the Microsoft 365 admin center.",
                "In the Microsoft Entra admin center, open App registrations and choose New registration (or reuse the Pennant app). Under Authentication, add Mobile and desktop applications with the redirect URL below.",
                "Under API permissions › APIs my organization uses, find Work IQ and add the WorkIQ-SharePointServer permission. Grant admin consent.",
                "Copy the Application (client) ID and the Directory (tenant) ID (a GUID) into the fields here. No client secret.",
            ],
            needsClientSecret: false
        ),
        MCPCatalogEntry(
            id: "workiq-onedrive", name: "Work IQ OneDrive", publisher: "Microsoft",
            summary: "Microsoft's OneDrive server: the files and folders in your OneDrive (needs a Microsoft 365 Copilot licence).",
            category: "Productivity", symbol: "icloud",
            url: "https://agent365.svc.cloud.microsoft/agents/tenants/{tenant}/servers/mcp_OneDriveRemoteServer",
            auth: .oauth(scopes: ["https://agent365.svc.cloud.microsoft/agents/tenants/{tenant}/servers/mcp_OneDriveRemoteServer/.default", "offline_access", "openid", "profile"], clientID: nil, clientSecret: nil),
            parameters: [.init(key: "tenant", label: "Directory (tenant) ID", placeholder: "00000000-0000-0000-0000-000000000000")],
            docsURL: "https://learn.microsoft.com/en-us/microsoft-agent-365/tooling-servers-overview",
            verified: true,
            brandColor: "#0078D4",
            needsRegisteredClient: true,
            oauthServer: microsoftOAuth,
            setupSteps: [
                "Work IQ servers need a Microsoft 365 Copilot licence and are in preview. An admin can allow or block them under Agents › Tools in the Microsoft 365 admin center.",
                "In the Microsoft Entra admin center, open App registrations and choose New registration (or reuse the Pennant app). Under Authentication, add Mobile and desktop applications with the redirect URL below.",
                "Under API permissions › APIs my organization uses, find Work IQ and add the WorkIQ-OneDriveServer permission. Grant admin consent.",
                "Copy the Application (client) ID and the Directory (tenant) ID (a GUID) into the fields here. No client secret.",
            ],
            needsClientSecret: false
        ),
        MCPCatalogEntry(
            id: "workiq-word", name: "Work IQ Word", publisher: "Microsoft",
            summary: "Microsoft's Word server: create and read documents and work with comments (needs a Microsoft 365 Copilot licence).",
            category: "Productivity", symbol: "doc.text",
            url: "https://agent365.svc.cloud.microsoft/agents/tenants/{tenant}/servers/mcp_WordServer",
            auth: .oauth(scopes: ["https://agent365.svc.cloud.microsoft/agents/tenants/{tenant}/servers/mcp_WordServer/.default", "offline_access", "openid", "profile"], clientID: nil, clientSecret: nil),
            parameters: [.init(key: "tenant", label: "Directory (tenant) ID", placeholder: "00000000-0000-0000-0000-000000000000")],
            docsURL: "https://learn.microsoft.com/en-us/microsoft-agent-365/tooling-servers-overview",
            verified: true,
            brandColor: "#0078D4",
            needsRegisteredClient: true,
            oauthServer: microsoftOAuth,
            setupSteps: [
                "Work IQ servers need a Microsoft 365 Copilot licence and are in preview. An admin can allow or block them under Agents › Tools in the Microsoft 365 admin center.",
                "In the Microsoft Entra admin center, open App registrations and choose New registration (or reuse the Pennant app). Under Authentication, add Mobile and desktop applications with the redirect URL below.",
                "Under API permissions › APIs my organization uses, find Work IQ and add the WorkIQ-WordServer permission. Grant admin consent.",
                "Copy the Application (client) ID and the Directory (tenant) ID (a GUID) into the fields here. No client secret.",
            ],
            needsClientSecret: false
        ),
        MCPCatalogEntry(
            id: "workiq-copilot", name: "Work IQ Copilot", publisher: "Microsoft",
            summary: "Microsoft 365 Copilot search and chat grounded in your work data (needs a Microsoft 365 Copilot licence).",
            category: "Productivity", symbol: "sparkle.magnifyingglass",
            url: "https://agent365.svc.cloud.microsoft/agents/tenants/{tenant}/servers/mcp_M365Copilot",
            auth: .oauth(scopes: ["https://agent365.svc.cloud.microsoft/agents/tenants/{tenant}/servers/mcp_M365Copilot/.default", "offline_access", "openid", "profile"], clientID: nil, clientSecret: nil),
            parameters: [.init(key: "tenant", label: "Directory (tenant) ID", placeholder: "00000000-0000-0000-0000-000000000000")],
            docsURL: "https://learn.microsoft.com/en-us/microsoft-agent-365/tooling-servers-overview",
            verified: true,
            brandColor: "#0078D4",
            needsRegisteredClient: true,
            oauthServer: microsoftOAuth,
            setupSteps: [
                "Work IQ servers need a Microsoft 365 Copilot licence and are in preview. An admin can allow or block them under Agents › Tools in the Microsoft 365 admin center.",
                "In the Microsoft Entra admin center, open App registrations and choose New registration (or reuse the Pennant app). Under Authentication, add Mobile and desktop applications with the redirect URL below.",
                "Under API permissions › APIs my organization uses, find Work IQ and add the WorkIQ-CopilotServer permission. Grant admin consent.",
                "Copy the Application (client) ID and the Directory (tenant) ID (a GUID) into the fields here. No client secret.",
            ],
            needsClientSecret: false
        ),

        // MARK: Business

        // HubSpot's own local server (npm @hubspot/mcp-server) takes a private-app access token; the remote server at
        // mcp.hubspot.com has no dynamic client registration, so its OAuth route needs an MCP connector created in
        // the developer console with the host's fixed redirect URL.
        MCPCatalogEntry(
            id: "hubspot", name: "HubSpot", publisher: "HubSpot",
            summary: "Contacts, companies, deals, and tickets from your HubSpot CRM, with a private-app token or the remote server's OAuth.",
            category: "Business", symbol: "person.2",
            url: "https://mcp.hubspot.com",
            command: "npx", arguments: ["-y", "@hubspot/mcp-server"],
            environment: ["PRIVATE_APP_ACCESS_TOKEN": "{PRIVATE_APP_ACCESS_TOKEN}"],
            parameters: [.init(key: "PRIVATE_APP_ACCESS_TOKEN", label: "Private app access token", kind: "secret", placeholder: "pat-…")],
            keyHelpURL: "https://developers.hubspot.com/docs/apps/legacy-apps/private-apps/overview",
            docsURL: "https://developers.hubspot.com/docs/apps/developer-platform/build-apps/integrate-with-the-remote-hubspot-mcp-server",
            verified: true,
            brandIcon: "hubspot", brandColor: "#FF7A59",
            alternateAuth: .oauthDefault, needsRegisteredClient: true
        ),
        MCPCatalogEntry(
            id: "intercom", name: "Intercom", publisher: "Intercom",
            summary: "Conversations, contacts, and help-center articles from your Intercom workspace.",
            category: "Business", symbol: "bubble.left.and.bubble.right",
            url: "https://mcp.intercom.com/mcp",
            auth: .oauthDefault,
            docsURL: "https://developers.intercom.com/docs/guides/mcp",
            verified: true,
            brandIcon: "intercom", brandColor: "#6AFDEF"
        ),
        MCPCatalogEntry(
            id: "stripe", name: "Stripe", publisher: "Stripe",
            summary: "Customers, payments, subscriptions, and invoices in your Stripe account.",
            category: "Business", symbol: "creditcard",
            url: "https://mcp.stripe.com/",
            auth: .oauthDefault,
            docsURL: "https://docs.stripe.com/mcp",
            verified: true,
            brandIcon: "stripe", brandColor: "#635BFF"
        ),
        MCPCatalogEntry(
            id: "paypal", name: "PayPal", publisher: "PayPal",
            summary: "Invoices, orders, subscriptions, and disputes from your PayPal business account.",
            category: "Business", symbol: "dollarsign.circle",
            url: "https://mcp.paypal.com/http",
            auth: .oauthDefault,
            docsURL: "https://developer.paypal.com/tools/mcp-server/",
            verified: true,
            brandIcon: "paypal", brandColor: "#002991"
        ),
        MCPCatalogEntry(
            id: "square", name: "Square", publisher: "Square",
            summary: "Catalog, orders, customers, and payments from your Square account.",
            category: "Business", symbol: "storefront",
            url: "https://mcp.squareup.com/mcp",
            auth: .oauthDefault,
            docsURL: "https://developer.squareup.com/docs/mcp",
            verified: true,
            brandIcon: "square", brandColor: "#3E4348"
        ),

        // MARK: Social

        // LinkedIn publishes no MCP server; Pennant calls its Posts API with the member's own app ("Share on LinkedIn"
        // and "Sign In with LinkedIn using OpenID Connect", both self-serve). The token exchange needs the secret in
        // the body, and the standard flow rejects PKCE parameters.
        MCPCatalogEntry(
            id: "linkedin", name: "LinkedIn", publisher: "LinkedIn",
            summary: "Post to your own LinkedIn feed with text, a link or an image, comment, and delete your posts, through your own LinkedIn app.",
            category: "Social", symbol: "person.crop.square",
            auth: .oauth(scopes: ["openid", "profile", "email", "w_member_social"], clientID: nil, clientSecret: nil),
            docsURL: "https://learn.microsoft.com/en-us/linkedin/consumer/integrations/self-serve/share-on-linkedin",
            verified: true,
            brandColor: "#0A66C2",
            needsRegisteredClient: true,
            builtin: "linkedin",
            oauthServer: OAuthServerConfig(
                authorizeURL: "https://www.linkedin.com/oauth/v2/authorization",
                tokenURL: "https://www.linkedin.com/oauth/v2/accessToken",
                secretInBody: true,
                usesPKCE: false,
                redirectHost: "localhost"
            ),
            setupSteps: [
                "At linkedin.com/developers/apps, choose Create app. LinkedIn asks for a company page to associate; your own company's page is fine.",
                "On the app's Products tab, add Sign In with LinkedIn using OpenID Connect and Share on LinkedIn. Both are approved straight away.",
                "On the Auth tab, add the redirect URL below under Authorized redirect URLs.",
                "Copy the Client ID and the Primary Client Secret into the fields here. LinkedIn tokens last 60 days; sign in again when Connections says so.",
            ],
            needsClientSecret: true
        ),
        // Reddit publishes no MCP server, and since 2026 its Data API needs approval under the Responsible Builder
        // Policy. Pennant calls the API as the user with an "installed app" (no secret; Basic auth with an empty
        // password) and a permanent refresh token.
        MCPCatalogEntry(
            id: "reddit", name: "Reddit", publisher: "Reddit",
            summary: "Read and search subreddits and threads, submit posts, comment and check your inbox as your Reddit account, once Reddit has approved your API access.",
            category: "Social", symbol: "bubble.left.and.text.bubble.right",
            auth: .oauth(scopes: ["identity", "read", "submit", "history", "privatemessages", "mysubreddits", "edit"], clientID: nil, clientSecret: nil),
            parameters: [.init(key: "username", label: "Your Reddit username", placeholder: "without u/")],
            docsURL: "https://support.reddithelp.com/hc/en-us/articles/42728983564564",
            verified: true,
            brandIcon: "reddit", brandColor: "#FF4500",
            needsRegisteredClient: true,
            builtin: "reddit",
            oauthServer: OAuthServerConfig(
                authorizeURL: "https://www.reddit.com/api/v1/authorize",
                tokenURL: "https://www.reddit.com/api/v1/access_token",
                extraAuthorizeParameters: ["duration": "permanent"],
                tokenHeaders: ["User-Agent": "macos:dev.pennant.mac:v1 (by /u/{username})"],
                basicAuthWithEmptySecret: true,
                usesPKCE: false,
                redirectHost: "localhost"
            ),
            setupSteps: [
                "Reddit approves API access by hand: request it at developers.reddit.com/app-registration (or Reddit's developer support form) and describe the use. Posting the same content across subreddits breaks its rules.",
                "Once approved, create an app of type installed app at reddit.com/prefs/apps with the redirect URL below.",
                "Copy the client ID (the string under the app's name) into the field here, and your username. Installed apps have no secret.",
            ],
            needsClientSecret: false
        ),

        // MARK: Design

        MCPCatalogEntry(
            id: "figma", name: "Figma", publisher: "Figma",
            summary: "Frames, components, and design tokens from your Figma files, ready to build from.",
            category: "Design", symbol: "paintbrush",
            url: "https://mcp.figma.com/mcp",
            auth: .oauthDefault,
            docsURL: "https://developers.figma.com/docs/figma-mcp-server/remote-server-installation/",
            verified: true,
            brandIcon: "figma", brandColor: "#F24E1E"
        ),
        MCPCatalogEntry(
            id: "canva", name: "Canva", publisher: "Canva",
            summary: "Find, create, and export designs in your Canva account.",
            category: "Design", symbol: "paintpalette",
            url: "https://mcp.canva.com/mcp",
            auth: .oauthDefault,
            docsURL: "https://www.canva.dev/docs/apps/mcp/",
            verified: true
        ),
        MCPCatalogEntry(
            id: "webflow", name: "Webflow", publisher: "Webflow",
            summary: "Sites, pages, and CMS collections from your Webflow workspace.",
            category: "Design", symbol: "rectangle.on.rectangle",
            url: "https://mcp.webflow.com/mcp",
            auth: .oauthDefault,
            docsURL: "https://developers.webflow.com/mcp/reference/getting-started",
            verified: true,
            brandIcon: "webflow", brandColor: "#146EF5"
        ),

        // MARK: Data

        MCPCatalogEntry(
            id: "neon", name: "Neon", publisher: "Neon",
            summary: "Create branches, run SQL, and manage the Postgres projects in your Neon account.",
            category: "Data", symbol: "cylinder",
            url: "https://mcp.neon.tech/mcp",
            auth: .oauthDefault,
            docsURL: "https://neon.com/docs/ai/neon-mcp-server",
            verified: true,
            brandIcon: "neon", brandColor: "#34D59A"
        ),
        MCPCatalogEntry(
            id: "supabase", name: "Supabase", publisher: "Supabase",
            summary: "Query tables, apply migrations, and manage the projects in your Supabase organization.",
            category: "Data", symbol: "cylinder.split.1x2",
            url: "https://mcp.supabase.com/mcp",
            auth: .oauthDefault,
            docsURL: "https://supabase.com/docs/guides/getting-started/mcp",
            verified: true,
            brandIcon: "supabase", brandColor: "#3FCF8E"
        ),
        MCPCatalogEntry(
            id: "huggingface", name: "Hugging Face", publisher: "Hugging Face",
            summary: "Search models, datasets, papers, and Spaces on the Hub, including your private ones.",
            category: "Data", symbol: "face.smiling",
            url: "https://huggingface.co/mcp",
            auth: .bearerKey,
            keyHelpURL: "https://huggingface.co/settings/tokens",
            docsURL: "https://huggingface.co/docs/hub/en/hf-mcp-server",
            verified: true,
            brandIcon: "huggingface", brandColor: "#FFD21E"
        ),
        MCPCatalogEntry(
            id: "postgres", name: "Postgres", publisher: "Crystal DBA",
            summary: "Explore schemas and run read-only queries against any Postgres database you can reach.",
            category: "Data", symbol: "cylinder.fill",
            command: "uvx", arguments: ["postgres-mcp", "--access-mode=restricted"],
            environment: ["DATABASE_URI": "{DATABASE_URI}"],
            parameters: [.init(key: "DATABASE_URI", label: "Connection string", kind: "secret", placeholder: "postgresql://user:password@host:5432/dbname")],
            docsURL: "https://github.com/crystaldba/postgres-mcp",
            verified: true,
            brandIcon: "postgresql", brandColor: "#4169E1"
        ),
        MCPCatalogEntry(
            id: "sqlite", name: "SQLite", publisher: "eQuill Labs",
            summary: "Query and update the tables of one SQLite file on this Mac.",
            category: "Data", symbol: "tablecells.badge.ellipsis",
            command: "npx", arguments: ["-y", "mcp-sqlite", "{database}"],
            parameters: [.init(key: "database", label: "Database file", kind: "text", placeholder: "/Users/you/data.sqlite")],
            docsURL: "https://github.com/jparkerweb/mcp-sqlite",
            verified: true,
            brandIcon: "sqlite", brandColor: "#003B57"
        ),

        // MARK: Web

        MCPCatalogEntry(
            id: "exa", name: "Exa", publisher: "Exa",
            summary: "Neural web search and page contents built for agents.",
            category: "Web", symbol: "magnifyingglass",
            url: "https://mcp.exa.ai/mcp",
            auth: .apiKey(header: "x-api-key", prefix: ""),
            keyHelpURL: "https://dashboard.exa.ai/api-keys",
            docsURL: "https://exa.ai/docs/reference/exa-mcp",
            verified: true
        ),
        MCPCatalogEntry(
            id: "firecrawl", name: "Firecrawl", publisher: "Firecrawl",
            summary: "Scrape, crawl, and search the web and get clean markdown back.",
            category: "Web", symbol: "flame",
            url: "https://mcp.firecrawl.dev/v2/mcp",
            auth: .bearerKey,
            keyHelpURL: "https://www.firecrawl.dev/app/api-keys",
            docsURL: "https://docs.firecrawl.dev/mcp-server",
            verified: true
        ),
        MCPCatalogEntry(
            id: "tavily", name: "Tavily", publisher: "Tavily",
            summary: "Web search and page extraction tuned for research agents.",
            category: "Web", symbol: "text.magnifyingglass",
            command: "npx", arguments: ["-y", "tavily-mcp"],
            environment: ["TAVILY_API_KEY": "{TAVILY_API_KEY}"],
            parameters: [.init(key: "TAVILY_API_KEY", label: "Tavily API key", kind: "secret", placeholder: "tvly-…")],
            keyHelpURL: "https://app.tavily.com/home",
            docsURL: "https://docs.tavily.com/documentation/mcp",
            verified: true
        ),
        MCPCatalogEntry(
            id: "brave-search", name: "Brave Search", publisher: "Brave",
            summary: "Web, news, image, and local search from the Brave index.",
            category: "Web", symbol: "magnifyingglass.circle",
            command: "npx", arguments: ["-y", "@brave/brave-search-mcp-server"],
            environment: ["BRAVE_API_KEY": "{BRAVE_API_KEY}"],
            parameters: [.init(key: "BRAVE_API_KEY", label: "Brave Search API key", kind: "secret", placeholder: "BSA…")],
            keyHelpURL: "https://api-dashboard.search.brave.com",
            docsURL: "https://github.com/brave/brave-search-mcp-server",
            verified: true,
            brandIcon: "brave", brandColor: "#FB542B"
        ),
        MCPCatalogEntry(
            id: "fetch", name: "Fetch", publisher: "Model Context Protocol",
            summary: "Download a web page and hand it to the agent as readable text.",
            category: "Web", symbol: "arrow.down.doc",
            command: "uvx", arguments: ["mcp-server-fetch"],
            docsURL: "https://github.com/modelcontextprotocol/servers/blob/main/src/fetch/README.md",
            verified: true
        ),
        MCPCatalogEntry(
            id: "playwright", name: "Playwright", publisher: "Microsoft",
            summary: "Drive a real browser: navigate, click, type, and read pages through the accessibility tree.",
            category: "Web", symbol: "macwindow",
            command: "npx", arguments: ["-y", "@playwright/mcp@latest"],
            docsURL: "https://github.com/microsoft/playwright-mcp",
            verified: true
        ),

        // MARK: Local

        MCPCatalogEntry(
            id: "filesystem", name: "Filesystem", publisher: "Model Context Protocol",
            summary: "Read, write, search, and move files inside one folder you choose.",
            category: "Local", symbol: "folder",
            command: "npx", arguments: ["-y", "@modelcontextprotocol/server-filesystem", "{folder}"],
            parameters: [.init(key: "folder", label: "Folder", kind: "folder", placeholder: "~/Documents")],
            docsURL: "https://github.com/modelcontextprotocol/servers/blob/main/src/filesystem/README.md",
            verified: true
        ),
        MCPCatalogEntry(
            id: "git", name: "Git", publisher: "Model Context Protocol",
            summary: "Status, diffs, log, and commits for one local repository.",
            category: "Local", symbol: "arrow.triangle.branch",
            command: "uvx", arguments: ["mcp-server-git", "--repository", "{repository}"],
            parameters: [.init(key: "repository", label: "Repository", kind: "folder", placeholder: "~/Projects/app")],
            docsURL: "https://github.com/modelcontextprotocol/servers/blob/main/src/git/README.md",
            verified: true,
            brandIcon: "git", brandColor: "#F03C2E"
        ),
        MCPCatalogEntry(
            id: "memory", name: "Memory", publisher: "Model Context Protocol",
            summary: "A small knowledge graph agents can add to and recall from between sessions.",
            category: "Local", symbol: "brain",
            command: "npx", arguments: ["-y", "@modelcontextprotocol/server-memory"],
            docsURL: "https://github.com/modelcontextprotocol/servers/blob/main/src/memory/README.md",
            verified: true
        ),
        MCPCatalogEntry(
            id: "time", name: "Time", publisher: "Model Context Protocol",
            summary: "The current time in any zone, and conversions between zones.",
            category: "Local", symbol: "clock",
            command: "uvx", arguments: ["mcp-server-time"],
            docsURL: "https://github.com/modelcontextprotocol/servers/blob/main/src/time/README.md",
            verified: true
        ),
        MCPCatalogEntry(
            id: "sequential-thinking", name: "Sequential Thinking", publisher: "Model Context Protocol",
            summary: "A scratchpad for step-by-step reasoning that agents can revise as they go.",
            category: "Local", symbol: "list.number",
            command: "npx", arguments: ["-y", "@modelcontextprotocol/server-sequential-thinking"],
            docsURL: "https://github.com/modelcontextprotocol/servers/blob/main/src/sequentialthinking/README.md",
            verified: true
        ),
    ]

    public static func entry(_ id: String) -> MCPCatalogEntry? { entries.first { $0.id == id } }

    /// Entries matching a search query (name, publisher, summary, category) and an optional category.
    public static func search(_ query: String, category: String? = nil, in entries: [MCPCatalogEntry] = entries) -> [MCPCatalogEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.filter { e in
            if let category, e.category != category { return false }
            guard !q.isEmpty else { return true }
            return e.name.lowercased().contains(q) || e.publisher.lowercased().contains(q)
                || e.summary.lowercased().contains(q) || e.category.lowercased().contains(q)
        }
    }
}

public extension MCPCatalogEntry {
    /// What the auth chip says: how the server signs in, or that it runs locally.
    var signInLabel: String {
        if isLocal { return "Runs on this Mac" }
        return auth.label
    }

    /// What the card's second action says, when the entry has an alternate sign-in.
    var alternateSignInLabel: String? {
        guard let alternateAuth else { return nil }
        switch alternateAuth {
        case .none: return "Connect without signing in"
        case .apiKey: return "Use a token instead"
        case .oauth: return "Sign in with OAuth instead"
        }
    }

    /// The entry as the alternate route sees it: `alternateAuth` promoted to `auth`, so `makeConfig` and the
    /// connect flows read it like any other entry. A local entry's alternate is the remote server at `url`, so its
    /// command line and parameters go; a remote entry's alternate keeps the primary as its own alternate. Nil
    /// without an alternate, or for a local entry without a URL.
    var alternate: MCPCatalogEntry? {
        guard let alternateAuth else { return nil }
        var e = self
        e.auth = alternateAuth
        if isLocal {
            guard url != nil else { return nil }
            e.command = nil
            e.arguments = []
            e.environment = [:]
            e.parameters = []
            e.alternateAuth = nil
        } else {
            e.alternateAuth = auth
        }
        return e
    }

    /// True when signing in needs a client id first: OAuth at a provider without dynamic registration, and none
    /// set on `auth` yet.
    var needsClientBeforeSignIn: Bool {
        guard !isLocal, needsRegisteredClient, case .oauth(_, let clientID, _) = auth else { return false }
        return (clientID ?? "").isEmpty
    }

    /// The entry with a hand-registered OAuth client on `auth`; unchanged for entries that do not sign in with OAuth.
    func withRegisteredClient(id: String, secret: String?, values: [String: String] = [:]) -> MCPCatalogEntry {
        guard case .oauth(let scopes, _, _) = auth else { return self }
        var e = self
        let trimmedSecret = secret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        e.auth = .oauth(scopes: scopes, clientID: id.trimmingCharacters(in: .whitespacesAndNewlines), clientSecret: trimmedSecret.isEmpty ? nil : trimmedSecret)
        e.presetValues = values.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return e
    }

    /// Every `{key}` placeholder referenced by the command, arguments, environment values, and URL.
    var placeholderKeys: Set<String> {
        var keys = Set<String>()
        var sources = [command ?? "", url ?? ""] + arguments + Array(environment.values)
        if let o = oauthServer { sources += [o.authorizeURL, o.tokenURL] + Array(o.tokenHeaders.values) }
        if case .oauth(let scopes, _, _) = auth { sources += scopes }
        for s in sources {
            var rest = Substring(s)
            while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
                let key = rest[rest.index(after: open) ..< close]
                if !key.isEmpty { keys.insert(String(key)) }
                rest = rest[rest.index(after: close)...]
            }
        }
        return keys
    }

    /// One value per parameter, using its placeholder text (or the key when there is none). For previews and tests.
    var sampleValues: [String: String] {
        var out: [String: String] = [:]
        for p in parameters { out[p.key] = p.placeholder.isEmpty ? p.key : p.placeholder }
        return out
    }
}

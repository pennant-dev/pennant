# Design system

Pennant's interface is light, quiet, and colourful only where colour carries meaning: jobs and status. The
interaction patterns follow the current crop of personal-agent apps (threads on the left, one conversation in the
middle, the agent's screen on the right) with Pennant's own branding and assets.

## Where it lives

| Piece | File | What it holds |
| --- | --- | --- |
| Tokens | `Sources/PennantUI/Theme.swift` | `PennantTheme` surfaces, ink, bubbles, buttons, radii; `PennantPalette` (10 accent swatches); status colours and labels; `Chip`, `StatusDot`, `.card()`, `SectionLabel`, `AgentAvatar`, timestamps |
| Avatars | `Sources/PennantUI/Avatars.swift` | `AgentGlyph` (job symbols), `AgentFlag` (glyph + colour + mood), `PennantMark` / `PennantShape` (the ribbon mark) |
| Controls | `Sources/PennantUI/Controls.swift` | pill button styles, round icon buttons, fields, `ChoiceMenu`, chip rows, `AutocompleteField`, `SearchablePicker`, `TimeZoneField`, `ColorDots`, `GlyphPicker`, `SelectableRow`, `PaneHeader`, `EmptyState`, `PathField` |
| App icon | `Scripts/make-icon.py` → `Apps/PennantMac/Assets.xcassets`, `Apps/PennantiOS/Assets.xcassets` | the ribbon, violet into blue, on a white tile, same geometry as `PennantShape` |

Every token adapts to dark mode through `Color.adaptive(light:dark:)`; views never use raw `.secondary`, `.gray`,
or `Color.accentColor` for chrome.

## Tokens

- Surfaces: `windowBackground` (content), `sidebarBackground` (thread list), `panelBackground` (inspector, strips),
  `cardBackground` / `cardElevated` (cards), `fieldBackground` (pills and inputs), `selection`, `hover`, `border`, `divider`.
- Ink: `ink`, `inkSecondary`, `inkTertiary`.
- Bubbles: `userBubble` (near-black, white text) and `assistantBubble` (light grey); in dark mode they invert.
- Buttons: `.pennantPrimary` (black pill), `.pennantSecondary` (grey pill), `.pennantDestructive`, `.pennantGhost`, compact
  variants, `.pennantIcon` / `.pennantIconFilled` round icon buttons.
- Radii: 8 (small), 12 (fields, cards), 16 (large cards), 18 (bubbles). Continuous corners everywhere.

## Zoom

View › Zoom In, Zoom Out and Actual Size (⌘+ or ⌘=, ⌘−, ⌘0) scale the Mac app's text from 80% to 150%, remembered
across launches (`PennantZoom`). macOS gives SwiftUI's text styles no size setting, so views set type with
`Font.zoomed(.callout)` (or `.zoomed(size:weight:)`) instead of `.callout`: at 100% that is the text style itself, and
reading the zoom while a view draws is what redraws it when the zoom changes. Layouts, column widths and minimum
window sizes stay as they are; the text and the symbols set with it grow inside them. The iPhone stays at 100% and
keeps Dynamic Type.

## Avatars: flags

Every agent flies a flag: a rounded field in its accent colour with an SF Symbol for its job (`AgentGlyph`, 24
of them: envelope for email, megaphone for posting, play for video, pulse for operations, nodes for
architecture, compass for general help, and so on). The `avatar` field stores `flag:<glyph>`. Profiles from
before the flags (`shape:<name>` or an emoji) get a glyph guessed from the start of the words in their name, then
their role (`AgentGlyph.resolve`), falling back to a stand-in for the old shape; nothing is rewritten in storage.
The symbol is white, or ink on light colours (Honey) where white would wash out.

`AvatarMood` derives from `AgentStatus` and only changes the flag: busy (acting) flutters, asleep (paused,
retired) fades, alarmed (error) gets a red dot. From 56 pt up the flag hangs from a thin pole. The editor picks the
job symbol from `GlyphPicker` and the colour from `ColorDots`. Faces were retired in the Pennant rename
(DECISIONS 33).

`PennantMark` is Pennant's mark: a pennant abstracted into a ribbon in the wind (`PennantShape`), violet (`#8B5CF6`, the "needs you" colour) into ocean blue (`#2F80ED`), also drawn by `Scripts/make-icon.py` for the app icon.

## Choose before you type

Free text is reserved for what is genuinely free: names, prompts, messages, search. Everything else is a choice:

- The agent: colour dots, shape row, tone chips, tool chips.
- Schedules: repeat chips, interval menu, time pickers, weekday chips, time-zone search, prompt starters, live preview.
- Settings: endpoint presets with model discovery, discovered hosts (Bonjour), menus for sizes and ports, folder pickers.
- Composer: `/` lists skills, the `+` menu holds actions.
- MCP: a catalog of services with one Connect button each; server templates with only the template's own blanks left to fill.

`AutocompleteField` renders inline (no popover, so focus stays in the field); `SearchablePicker` opens a popover
with its own search box for long lists (time zones, models). Use the former for short, typed-through lists and the
latter for anything over a few dozen entries.

## Connecting services (MCP)

Connections opens with the marketplace: a search field, category chips (All, Developer, Productivity, Business,
Design, Data, Web, Local), and an adaptive grid of cards (`MCPMarketplaceView`). Each card is the service's mark
(`BrandIcon`), the name, the publisher, one sentence, a chip for how it signs in (OAuth, API key, No sign-in, Runs
on this Mac), and a trailing **Connect**. Once a server made from that entry exists, the card
mirrors it (Connected · 12 tools, Sign in needed, Waiting in browser…, Expired) and swaps Connect for **Manage**,
which scrolls to the server card and flashes its outline. Entries not checked against the publisher's docs carry
a small "Unverified" chip that opens the docs.

Connect asks only for what the entry needs (`MCPConnectFlow`): OAuth adds the server and opens the browser, an
API key gets a sheet with a secure field and a "Where do I get a key?" link, a local server gets one field per
placeholder (folder picker, secure field, or text), and no-auth servers are added straight away. Server cards
carry the sign-in line (kind chip, state chip, the host's one-line detail) and the actions the state allows: Sign
in, Set key…, Change key…, Sign out, Cancel. The browser step can only finish on the Mac running the host, so
other devices get the link to carry over instead of a broken redirect.

Brand marks come from Simple Icons (CC0; the marks stay their owners' trademarks and only say which service a
card connects to). `Scripts/fetch-brand-icons.swift` downloads each slug, rasterises it black at 1x/2x/3x, and
writes `Sources/PennantUI/Resources/BrandIcons.xcassets` as template images; a catalog entry names its asset
(`brandIcon`) and colour (`brandColor`). `BrandTint` keeps the colour readable on a 12% tint of itself in both
appearances: greys (GitHub, Notion, Square) draw in ink and invert in dark mode, bright colours are darkened for
light mode, deep ones brightened for dark mode, all in linear light so the hue holds. Entries without a mark in
the set (monday.com, Canva, Playwright, the MCP reference servers, among others) keep their SF Symbol in the category tint, and
server cards and the connect sheets show the same mark as the card.

The custom "Add server" sheet keeps the templates and adds a Sign-in choice for remote servers: API key with a
header preset (Authorization: Bearer, X-API-Key, or a custom header and prefix) and the secret, or OAuth with
optional scopes and a disclosure for a client you registered yourself. Secrets never sit in the config; the host
stores them in its Keychain right after the server is added.

## Inference provider

The provider choice lives in Settings › Host settings › Inference, as a chip row: **OpenAI-compatible endpoint**
keeps the base-URL presets, model discovery, key, window, and capability toggles; **ChatGPT account** replaces
them with an Account block (Sign in with ChatGPT opens the browser and the card waits for the host's loopback
redirect; Use Codex CLI login reuses `~/.codex/auth.json`; signed in shows the email, plan and source chips, and
Sign out) and a Model menu over the account's own list (the host's built-in one when the account can't be asked,
with a line saying why), whose subtitle carries the context window that the model brings with it, and Other model…
for any id. The model chip in the conversation header follows the host's word, not the unsaved form:
for a ChatGPT host its endpoint line reads "ChatGPT account · email", its rows are that list with the window
and vision note, picking one saves the model and window together, and a "Signed out · Sign in…" line points
at Settings. The Connections inference card shows the provider first, then the account or the endpoint.

The chip row has four providers: **Azure AI Foundry**, the endpoint (**OpenAI-compatible**), **ChatGPT account**, and
**Apple on-device**.
The endpoint's Base URL picker is the preset catalogue (`InferencePresets` in PennantCore, one row per vendor with
the name, the base URL, and "(unverified)" on the entries nobody confirmed against the vendor's docs); picking a
row sets the URL and the preset tag, flips the vision and tools toggles to what the vendor documents, and adopts a
model id from its docs when the current one belongs to another vendor. Under the key field a "Where do I get a
<vendor> key?" link and a docs link follow the preset, an Unverified chip marks the hypotheses, and a note under the
picker carries the quirks worth knowing before the first call (Anthropic's capped temperature and prompted JSON
mode, Z.ai's separate coding-plan billing). A preset without a models route hides the refresh button and offers
its example ids in the model menu instead; a typed URL clears the tag and is a custom endpoint as before. The ChatGPT
account waits for the browser sign-in; signed in, it shows the email, the plan, where the login came from (Pennant or
the Codex CLI), and Sign out. The model chip reads "ChatGPT account · email" for a ChatGPT host, "On this Mac" with no
list for Apple, and "<Preset> · <URL>" for an endpoint whose base URL is a preset; the Connections card adds an
Account row for the sign-in providers, "On this Mac" for Apple, and a Preset row for a known endpoint.

## Markdown

Agent and user text goes through `PennantMarkdown` (Sources/PennantUI/MarkdownView.swift), a MarkdownUI theme built from
the tokens: `Theme.pennant` for light bubbles and `Theme.pennantOnDark` for the black user bubble. Block styles are small
wrapper views because SwiftUI modifiers must run on the main actor and MarkdownUI's style closures do not.


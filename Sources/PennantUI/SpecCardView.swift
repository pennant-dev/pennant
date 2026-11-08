import PennantCore
import SwiftUI
import WebKit

/// A card drawn by json-render with its components (shadcn/ui), from the page bundled in Resources/PennantCards.html
/// (built from Web/cards), in the app's light or dark look and text size.
///
/// Every web view costs a WebKit process, so the conversation shows each card as a picture one hidden web view drew
/// (`CardPictures`), and only the card under the pointer (on the iPhone, the one last tapped) is live: tabs switch,
/// text selects, and a tap sends back what it asks for (words to reply with, a link to open).
struct SpecCardView: View {
    var id: String
    var spec: JSONValue
    /// Sends words to the conversation as the owner's reply; nil where there's no conversation to reply in.
    var reply: ((String) -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @State private var width: CGFloat = 0
    @State private var picture: CardPicture?
    @State private var liveHeight: CGFloat = 0
    private var liveCard = LiveCard.shared

    init(id: String, spec: JSONValue, reply: ((String) -> Void)? = nil) {
        self.id = id; self.spec = spec; self.reply = reply
    }

    private var isLive: Bool { liveCard.id == id && picture != nil }
    private var liveReady: Bool { isLive && liveHeight > 0 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let picture {
                Image(decorative: picture.image, scale: picture.scale)
                    .resizable()
                    .frame(width: picture.width, height: picture.height)
                    .opacity(liveReady ? 0 : 1)
            } else {
                RoundedRectangle(cornerRadius: PennantTheme.radiusLarge, style: .continuous)
                    .fill(PennantTheme.cardBackground.opacity(0.6))
            }
            if isLive {
                SpecWebView(spec: spec, appearance: appearance, height: $liveHeight, onAction: act)
                    .opacity(liveReady ? 1 : 0)
            }
        }
        .frame(maxWidth: 720, alignment: .topLeading)
        .frame(height: liveReady ? liveHeight : picture?.height ?? 160, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: PictureKey(spec: spec, width: width, appearance: appearance)) { await drawPicture() }
        #if os(macOS)
        .onHover { inside in
            if inside { liveCard.id = id } else if liveCard.id == id { liveCard.id = nil }
        }
        #else
        .onTapGesture { liveCard.id = id }
        #endif
        .onChange(of: isLive) { _, live in if !live { liveHeight = 0 } }
    }

    private func drawPicture() async {
        guard width > 0 else { return }
        // While a window is being resized, wait for it to settle before drawing again.
        if picture != nil { try? await Task.sleep(for: .milliseconds(150)) }
        guard !Task.isCancelled, let drawn = await CardPictures.shared.picture(of: spec, width: width, appearance: appearance) else { return }
        if !Task.isCancelled { picture = drawn }
    }

    private func act(_ action: String, _ params: [String: Any]) {
        switch action {
        case "reply": if let text = params["text"] as? String, !text.isEmpty { reply?(text) }
        case "open": if let raw = params["url"] as? String, let url = URL(string: raw), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { openURL(url) }
        default: break
        }
    }

    private var appearance: SpecWebView.Appearance {
        #if os(macOS)
        let size = 13 * PennantZoom.shared.factor
        #else
        let size = UIFont.preferredFont(forTextStyle: .subheadline).pointSize
        #endif
        return .init(dark: colorScheme == .dark, fontSize: size)
    }
}

/// Which card is live: one at a time across the app.
@MainActor @Observable final class LiveCard {
    static let shared = LiveCard()
    var id: String?
}

struct PictureKey: Hashable {
    var spec: JSONValue
    var width: CGFloat
    var appearance: SpecWebView.Appearance
}

/// A card as drawn: the image at the screen's scale, and its size in points.
struct CardPicture {
    var image: CGImage
    var scale: CGFloat
    var width: CGFloat
    var height: CGFloat
}

/// Draws cards as pictures in one hidden web view, one at a time, and keeps the recent ones.
@MainActor final class CardPictures {
    static let shared = CardPictures()
    private var web: CardWebView?
    private var ready: Task<Bool, Never>?
    private var queue: Task<Void, Never>?
    private var kept: [PictureKey: CardPicture] = [:]
    private var order: [PictureKey] = []
    private let keep = 60

    func picture(of spec: JSONValue, width: CGFloat, appearance: SpecWebView.Appearance) async -> CardPicture? {
        let key = PictureKey(spec: spec, width: width, appearance: appearance)
        if let hit = kept[key] { return hit }
        // One at a time: the web view holds one card.
        let previous = queue
        let job = Task { () -> CardPicture? in
            await previous?.value
            if let hit = kept[key] { return hit }
            guard let drawn = await draw(spec, width: width, appearance: appearance) else { return nil }
            kept[key] = drawn
            order.append(key)
            if order.count > keep { kept[order.removeFirst()] = nil }
            return drawn
        }
        queue = Task { _ = await job.value }
        return await job.value
    }

    private func draw(_ spec: JSONValue, width: CGFloat, appearance: SpecWebView.Appearance) async -> CardPicture? {
        guard let web = await loadedWebView(), let data = try? JSONEncoder().encode(spec), let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        web.frame = CGRect(x: 0, y: 0, width: width, height: max(web.frame.height, 200))
        let options: [String: Any] = ["dark": appearance.dark, "fontSize": Double(appearance.fontSize)]
        guard let result = try? await web.callAsyncJavaScript("return await PennantCards.draw(spec, options)", arguments: ["spec": object, "options": options], contentWorld: .page),
              let height = (result as? NSNumber).map({ CGFloat($0.doubleValue) }), height > 0 else { return nil }
        web.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let image = try? await web.takeSnapshot(configuration: config) else { return nil }
        #if os(macOS)
        let scale = web.window?.backingScaleFactor ?? 2
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #else
        let scale = image.scale
        guard let cg = image.cgImage else { return nil }
        #endif
        return CardPicture(image: cg, scale: scale, width: width, height: height)
    }

    private func loadedWebView() async -> CardWebView? {
        if ready == nil {
            let loader = PageLoader()
            let web = SpecWebView.makePlainWebView()
            web.navigationDelegate = loader
            Self.hide(web)
            self.web = web
            ready = Task { await loader.load(web) }
        }
        return await ready?.value == true ? web : nil
    }

    /// Off screen but in a window, so WebKit draws it.
    private static func hide(_ web: CardWebView) {
        #if os(macOS)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.ignoresMouseEvents = true
        let holder = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = holder
        holder.addSubview(web)
        window.orderBack(nil)
        #else
        let host = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        web.isUserInteractionEnabled = false
        host?.insertSubview(web, at: 0)
        web.transform = CGAffineTransform(translationX: -20000, y: 0)
        #endif
    }

    /// Waits for the card page to finish loading.
    @MainActor final class PageLoader: NSObject, WKNavigationDelegate {
        private var done: CheckedContinuation<Bool, Never>?
        func load(_ web: WKWebView) async -> Bool {
            guard let page = SpecWebView.page else { return false }
            return await withCheckedContinuation { continuation in
                done = continuation
                web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
            }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(returning: true); done = nil }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { done?.resume(returning: false); done = nil }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { done?.resume(returning: false); done = nil }
    }
}

/// The live card: the page in a web view that sizes itself to the card and passes taps back.
@MainActor struct SpecWebView {
    struct Appearance: Hashable { var dark: Bool; var fontSize: CGFloat }

    var spec: JSONValue
    var appearance: Appearance
    @Binding var height: CGFloat
    var onAction: (String, [String: Any]) -> Void

    static let page = Bundle.module.url(forResource: "PennantCards", withExtension: "html")
    /// One store for every card's web view.
    static let store = WKWebsiteDataStore.nonPersistent()

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    static func makePlainWebView(handler: WKScriptMessageHandler? = nil) -> CardWebView {
        let config = WKWebViewConfiguration()
        if let handler { config.userContentController.add(handler, name: "pennant") }
        config.websiteDataStore = store
        let web = CardWebView(frame: .zero, configuration: config)
        #if os(macOS)
        web.setValue(false, forKey: "drawsBackground")
        #else
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        #endif
        return web
    }

    func makeWebView(_ coordinator: Coordinator) -> CardWebView {
        let web = Self.makePlainWebView(handler: WeakHandler(coordinator))
        web.navigationDelegate = coordinator
        coordinator.web = web
        if let page = Self.page { web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent()) }
        return web
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: SpecWebView
        weak var web: WKWebView?
        private var loaded = false
        private var drawnSpec: JSONValue?
        private var drawnAppearance: Appearance?

        init(_ parent: SpecWebView) { self.parent = parent }

        /// Draws what changed since the last call, once the page is ready. It draws still, like the picture it
        /// takes the place of.
        func update(_ parent: SpecWebView) {
            self.parent = parent
            guard loaded, let web else { return }
            var script = ""
            if drawnAppearance != parent.appearance {
                script += "PennantCards.setAppearance({dark: \(parent.appearance.dark), fontSize: \(Double(parent.appearance.fontSize)), still: true});"
                drawnAppearance = parent.appearance
            }
            if drawnSpec != parent.spec, let data = try? JSONEncoder().encode(parent.spec), let json = String(data: data, encoding: .utf8) {
                script += "PennantCards.render(\(json));"
                drawnSpec = parent.spec
            }
            if !script.isEmpty { web.evaluateJavaScript(script, completionHandler: nil) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            update(parent)
        }

        /// The card's page is the only page it shows; links go through `open`, to the owner's browser.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel)
        }

        func received(_ body: Any) {
            guard let body = body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "height":
                if let value = body["value"] as? Double, value > 0, abs(CGFloat(value) - parent.height) > 0.5 { parent.height = CGFloat(value) }
            case "action":
                if let name = body["name"] as? String { parent.onAction(name, body["params"] as? [String: Any] ?? [:]) }
            default:
                break
            }
        }
    }

    /// The content controller keeps its handlers alive; this keeps it from keeping the coordinator alive too.
    @MainActor final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var coordinator: Coordinator?
        init(_ coordinator: Coordinator) { self.coordinator = coordinator }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            coordinator?.received(message.body)
        }
    }
}

#if os(macOS)
/// A card never scrolls on its own: the wheel goes to the conversation around it.
final class CardWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}

extension SpecWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> CardWebView { makeWebView(context.coordinator) }
    func updateNSView(_ view: CardWebView, context: Context) { context.coordinator.update(self) }
}
#else
final class CardWebView: WKWebView {}

extension SpecWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> CardWebView { makeWebView(context.coordinator) }
    func updateUIView(_ view: CardWebView, context: Context) { context.coordinator.update(self) }
}
#endif

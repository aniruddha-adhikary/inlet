import AppKit
import Observation
import WebKit

/// A web app the user signs into inside Chatbridge. After sign-in the window
/// closes and the page keeps running hidden, read by profile-driven scripts.
/// Strictly one-way: the page can hand records to the app, nothing flows back
/// into the page except the profile it should use.
@Observable
final class SourceSession: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    enum State: Equatable {
        case idle, loading, needsLogin, connected
        case failed(String)
    }

    struct Descriptor: Identifiable {
        let id: String              // app id used by the profiles, e.g. net.whatsapp.web
        let name: String
        let symbol: String
        let tint: String            // "green", "blue": brand-adjacent colour for the source's tile
        let url: URL
        /// Hosts the main frame may navigate to. Anything else opens in the default browser.
        let allowedHosts: Set<String>
        /// JS evaluated in the page; returns "connected", "login" or "loading". Reads structure only.
        let loginProbe: String
        let needsStorePage: Bool    // inject the in-page store reader (page world)
        let note: String?
    }

    static let catalog: [Descriptor] = [
        Descriptor(
            id: "net.whatsapp.web", name: "WhatsApp", symbol: "message.fill", tint: "green",
            url: URL(string: "https://web.whatsapp.com/")!, allowedHosts: ["web.whatsapp.com"],
            loginProbe: "document.querySelector('#pane-side, #side') ? 'connected' : document.querySelector('canvas, [data-ref]') ? 'login' : 'loading'",
            needsStorePage: true, note: nil),
        Descriptor(
            id: "org.telegram.web", name: "Telegram", symbol: "paperplane.fill", tint: "blue",
            url: URL(string: "https://web.telegram.org/k/")!, allowedHosts: ["web.telegram.org"],
            loginProbe: "document.querySelector('.chatlist, #column-left .chatlist-container') ? 'connected' : document.querySelector('.auth-pages, .page-sign, .auth-form') ? 'login' : 'loading'",
            needsStorePage: true, note: nil),
    ]

    let descriptor: Descriptor
    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            DebugLog.write("\(descriptor.name) state: \(state)")
            if state == .connected { UserDefaults.standard.set(true, forKey: connectedKey) }
        }
    }
    private(set) var lastIngest: String?

    @ObservationIgnored private var webView: WKWebView?
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var probe: Task<Void, Never>?
    @ObservationIgnored private var autoHidden = false

    private var connectedKey: String { "source.connected.\(descriptor.id)" }
    /// True once the user has signed in at least once: only then is the session restored silently at launch.
    var wasConnected: Bool { UserDefaults.standard.bool(forKey: connectedKey) }

    private static let world = WKContentWorld.world(name: "Chatbridge")
    // Web messengers refuse unknown browsers; WKWebView's default UA lacks the Safari token.
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"

    init(_ descriptor: Descriptor) { self.descriptor = descriptor }

    // MARK: Lifecycle

    func start(showWindow: Bool) {
        if webView == nil { build() }
        if showWindow { show() }
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func hide() { window?.orderOut(nil) }

    /// Signs out locally: drops the web session for this source's sites only.
    func disconnect() async {
        probe?.cancel()
        window?.close()
        webView = nil
        window = nil
        state = .idle
        lastIngest = nil
        UserDefaults.standard.set(false, forKey: connectedKey)
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let mine = records.filter { r in descriptor.allowedHosts.contains { $0.hasSuffix(r.displayName) || r.displayName.hasSuffix($0) } }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: mine)
    }

    private func build() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // keeps the linked-device session across launches
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let content = config.userContentController
        content.addScriptMessageHandler(self, contentWorld: Self.world, name: "chatbridge")
        // Only the store reader runs in the page's own world (it must see the app's modules);
        // everything that talks to Chatbridge stays isolated from page scripts.
        if descriptor.needsStorePage { content.addUserScript(script("pagestore", world: .page)) }
        content.addUserScript(script("extractor", world: Self.world))
        content.addUserScript(script("content", world: Self.world))

        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: config)
        view.customUserAgent = Self.userAgent
        view.navigationDelegate = self
        view.uiDelegate = self
        webView = view

        let win = NSWindow(
            contentRect: view.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = "Sign in to \(descriptor.name)"
        win.contentView = view
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        window = win

        state = .loading
        view.load(URLRequest(url: descriptor.url))
        startProbe()
    }

    private func script(_ name: String, world: WKContentWorld) -> WKUserScript {
        let source = Bundle.main.url(forResource: name, withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world)
    }

    // Closing the window must not end the session: hide instead.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    // MARK: Containment

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard action.targetFrame?.isMainFrame ?? true, let url = action.request.url else { return .allow }
        if url.scheme == "about" || url.scheme == "blob" { return .allow }
        if url.scheme == "https", let host = url.host, descriptor.allowedHosts.contains(host) { return .allow }
        if ["http", "https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) } // links leave the session window
        return .cancel
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, ["http", "https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
        return nil
    }

    private func startProbe() {
        probe?.cancel()
        probe = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, let webView = self.webView else { return }
                let result = try? await webView.evaluateJavaScript(self.descriptor.loginProbe) as? String
                switch result {
                case "connected":
                    self.state = .connected
                    if !self.autoHidden, self.window?.isVisible == true {
                        self.autoHidden = true
                        try? await Task.sleep(for: .seconds(2))
                        self.hide()
                    }
                case "login":
                    self.state = .needsLogin
                    self.autoHidden = false
                    if self.window?.isVisible == false { self.show() } // link expired: ask again
                default:
                    break
                }
            }
        }
    }

    // MARK: Page -> app (the only channel out of the page)

    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        let origin = message.frameInfo.securityOrigin
        let pageHost = origin.port == 0 ? origin.host : "\(origin.host):\(origin.port)"
        guard message.frameInfo.isMainFrame, origin.protocol == "https", descriptor.allowedHosts.contains(origin.host),
              let body = message.body as? [String: Any], let method = body["method"] as? String,
              let path = body["path"] as? String
        else { return (["ok": false, "status": 403, "data": ["error": "origin not allowed"]], nil) }

        if method == "GET", path.hasPrefix("/profiles?host=") {
            let store = BridgeStore.default
            let profiles = ProfileLibrary.shared.profiles(forHost: pageHost) { store.profileStatus($0) == "quarantined" }
            return (["ok": true, "status": 200, "data": ["profiles": profiles]], nil)
        }
        if method == "POST", path == "/ingest", let batch = body["body"] as? [String: Any],
           let batchJSON = try? JSONSerialization.data(withJSONObject: batch) {
            let result = await Task.detached { Ingest.run(batchJSON: batchJSON, pageHost: pageHost) }.value
            let b = ((try? JSONSerialization.jsonObject(with: result.bodyJSON)) as? [String: Any]) ?? [:]
            if result.status == 200 {
                lastIngest = "\(b["inserted"] ?? 0) new · \(b["updated"] ?? 0) updated"
            }
            DebugLog.write("ingest \(descriptor.name): \(result.status) seen=\(b["seen"] ?? 0) inserted=\(b["inserted"] ?? 0) updated=\(b["updated"] ?? 0) rejected=\(b["rejected"] ?? 0) canary=\(b["canary"] ?? "-")")
            return (["ok": (200..<300).contains(result.status), "status": result.status, "data": b], nil)
        }
        return (["ok": false, "status": 404, "data": ["error": "not found"]], nil)
    }
}

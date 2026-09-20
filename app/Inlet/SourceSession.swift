import AppKit
import Observation
import SwiftUI
import WebKit

/// A web app the user signs into inside Inlet. After sign-in the window
/// closes and the page keeps running hidden, read by profile-driven scripts.
/// Strictly one-way: the page can hand records to the app, nothing flows back
/// into the page except the profile it should use.
@Observable
final class SourceSession: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    enum State: Equatable {
        case idle, loading, needsLogin, connected
        case failed(String)
    }

    let descriptor: AppDescriptor
    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            DebugLog.write("\(descriptor.name) state: \(state)")
            if state == .connected { UserDefaults.standard.set(true, forKey: connectedKey) }
        }
    }
    /// Diagnostics only: counts from the last batch, never content.
    private(set) var lastIngest: String?
    private(set) var lastIngestAt: Date?

    @ObservationIgnored private var webView: WKWebView?
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var probe: Task<Void, Never>?
    @ObservationIgnored private var autoHidden = false

    private var connectedKey: String { "source.connected.\(descriptor.id)" }
    /// True once the user has signed in at least once: only then is the session restored silently at launch.
    var wasConnected: Bool { UserDefaults.standard.bool(forKey: connectedKey) }

    private static let world = WKContentWorld.world(name: "Inlet")
    // Web messengers refuse unknown browsers; WKWebView's default UA lacks the Safari token.
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"

    init(_ descriptor: AppDescriptor) { self.descriptor = descriptor }

    // MARK: Lifecycle

    /// `--offline` (tests, development): never load a web session, so repeated launches
    /// can't look like abuse to the services the user is signed in to.
    static let isOffline = CommandLine.arguments.contains("--offline")

    func start(showWindow: Bool) {
        guard !Self.isOffline else { return }
        if webView == nil { build() }
        if showWindow { show() }
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func hide() { window?.orderOut(nil) }

    /// Stops reading without signing out: the page is unloaded, the web session stays.
    func pause() {
        probe?.cancel()
        window?.orderOut(nil)
        webView?.stopLoading()
        webView = nil
        window = nil
        state = .idle
    }

    /// Signs out locally: drops the web session for this source's sites only.
    func disconnect() async {
        pause()
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
        content.addScriptMessageHandler(self, contentWorld: Self.world, name: "inlet")
        // Only the store reader runs in the page's own world (it must see the app's modules);
        // everything that talks to Inlet stays isolated from page scripts.
        if descriptor.needsStorePage { content.addUserScript(script("pagestore", world: .page)) }
        content.addUserScript(script("extractor", world: Self.world))
        content.addUserScript(script("content", world: Self.world))

        guard let url = descriptor.url else { state = .failed("unavailable"); return }
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: config)
        view.customUserAgent = Self.userAgent
        view.navigationDelegate = self
        view.uiDelegate = self
        webView = view

        let win = NSWindow(
            contentRect: view.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = "Sign in to \(descriptor.name)"
        win.contentView = SignInChrome.wrap(view, appName: descriptor.name)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        window = win

        state = .loading
        view.load(URLRequest(url: url))
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
                    self.autoHidden = false // no surprise windows: the menu bar icon asks the user to sign in again
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
                lastIngestAt = Date()
            }
            DebugLog.write("ingest \(descriptor.name): \(result.status) seen=\(b["seen"] ?? 0) inserted=\(b["inserted"] ?? 0) updated=\(b["updated"] ?? 0) rejected=\(b["rejected"] ?? 0) canary=\(b["canary"] ?? "-")")
            return (["ok": (200..<300).contains(result.status), "status": result.status, "data": b], nil)
        }
        return (["ok": false, "status": 404, "data": ["error": "not found"]], nil)
    }
}

/// The strip above every sign-in page: says, at the moment it matters, who the user is talking to.
private enum SignInChrome {
    static func wrap(_ webView: WKWebView, appName: String) -> NSView {
        let strip = NSHostingView(rootView:
            Label("You're signing in to \(appName) directly. Inlet never sees your password.", systemImage: "lock.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.bar))
        let stack = NSStackView(views: [strip, webView])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.distribution = .fill
        strip.setContentHuggingPriority(.required, for: .vertical)
        webView.setContentHuggingPriority(.defaultLow, for: .vertical)
        return stack
    }
}

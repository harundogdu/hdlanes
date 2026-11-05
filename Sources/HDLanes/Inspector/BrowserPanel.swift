import AppKit
import HDCore
import SwiftUI
import WebKit

/// Browser tab: a per-session web view for the dev server the agent started.
struct BrowserPanel: View {
    let sessionID: UUID

    @Environment(AppModel.self) private var model

    var body: some View {
        let browser = BrowserSessions.session(for: sessionID, keeping: Set(model.state.sessions.map(\.id)))
        let detected = model.runtimes[sessionID]?.detectedURLs ?? []
        VStack(spacing: 0) {
            BrowserToolbar(browser: browser)
            if browser.isLoading {
                ProgressView(value: max(0.05, browser.progress))
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                    .frame(height: 2)
            }
            if !detected.isEmpty {
                DetectedURLChips(urls: Array(detected.reversed()), current: browser.currentURL) { browser.load($0) }
            }
            Divider()
            if let error = browser.errorMessage {
                BrowserErrorBar(message: error, onRetry: { browser.retry() }, onDismiss: { browser.errorMessage = nil })
            }
            ZStack {
                WebViewHost(webView: browser.webView)
                if browser.currentURL == nil && !browser.isLoading {
                    CompactEmptyState(title: L.browserEmptyTitle, symbol: "globe", detail: L.browserEmptyDetail)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.background)
                }
            }
        }
        .onAppear { autoLoad(browser, detected) }
        .onChange(of: detected) { autoLoad(browser, detected) }
    }

    /// A blank browser follows the newest URL the terminal printed.
    private func autoLoad(_ browser: BrowserSession, _ detected: [URL]) {
        guard browser.isBlank, let newest = detected.last else { return }
        browser.load(newest)
    }
}

private struct BrowserToolbar: View {
    @Bindable var browser: BrowserSession

    var body: some View {
        HStack(spacing: 4) {
            Button { browser.webView.goBack() } label: { Label(L.back, systemImage: "chevron.left").labelStyle(.iconOnly) }
                .disabled(!browser.canGoBack)
                .help(L.back)
            Button { browser.webView.goForward() } label: { Label(L.forward, systemImage: "chevron.right").labelStyle(.iconOnly) }
                .disabled(!browser.canGoForward)
                .help(L.forward)
            if browser.isLoading {
                Button { browser.webView.stopLoading() } label: { Label(L.stopLoading, systemImage: "xmark").labelStyle(.iconOnly) }
                    .help(L.stopLoading)
            } else {
                Button { browser.retry() } label: { Label(L.reload, systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
                    .disabled(browser.currentURL == nil && BrowserAddress.parse(browser.address).url == nil)
                    .help(L.reload)
            }
            TextField(L.addressPlaceholder, text: $browser.address)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit { browser.submitAddress() }
            Button {
                if let url = browser.currentURL { NSWorkspace.shared.open(url) }
            } label: {
                Label(L.openInDefaultBrowser, systemImage: "safari").labelStyle(.iconOnly)
            }
            .disabled(browser.currentURL == nil)
            .help(L.openInDefaultBrowser)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}

private struct DetectedURLChips: View {
    let urls: [URL]
    let current: URL?
    let onSelect: (URL) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(urls, id: \.self) { url in
                    Button { onSelect(url) } label: {
                        Text(verbatim: BrowserAddress.shortLabel(url))
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(url == current ? .accentColor : nil)
                    .help(L.detectedURLsHelp)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 5)
        }
    }
}

private struct BrowserErrorBar: View {
    let message: String
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 1) {
                Text(L.browserLoadFailed)
                    .font(.system(size: 11, weight: .medium))
                Text(verbatim: message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 4)
            Button(L.tryAgain, action: onRetry)
                .controlSize(.small)
            Button(action: onDismiss) { Label(L.dismiss, systemImage: "xmark").labelStyle(.iconOnly) }
                .buttonStyle(.borderless)
                .help(L.dismiss)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.red.opacity(0.08))
    }
}

// MARK: - Web view state

/// Keeps one web view per session alive while the app runs, so switching tabs or sessions doesn't reload pages.
@MainActor
enum BrowserSessions {
    private static var sessions: [UUID: BrowserSession] = [:]

    static func session(for id: UUID, keeping alive: Set<UUID>) -> BrowserSession {
        for key in sessions.keys where !alive.contains(key) { sessions.removeValue(forKey: key) }
        if let s = sessions[id] { return s }
        let s = BrowserSession()
        sessions[id] = s
        return s
    }
}

@MainActor
@Observable
final class BrowserSession {
    let webView: WKWebView
    var address = ""
    var isLoading = false
    var progress: Double = 0
    var canGoBack = false
    var canGoForward = false
    var currentURL: URL?
    var errorMessage: String?

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private let navigation = BrowserNavigationDelegate()

    init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        navigation.owner = self
        webView.navigationDelegate = navigation
        observe()
    }

    /// Nothing loaded and nothing on the way.
    var isBlank: Bool { webView.url == nil && !webView.isLoading }

    func load(_ url: URL) {
        errorMessage = nil
        address = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    func submitAddress() {
        switch BrowserAddress.parse(address) {
        case .url(let url): load(url)
        case .invalid: errorMessage = L.browserInvalidAddress
        case .unsupportedScheme: errorMessage = L.browserOnlyHTTP
        }
    }

    func retry() {
        errorMessage = nil
        if webView.url != nil {
            webView.reload()
        } else {
            submitAddress()
        }
    }

    fileprivate func failed(_ error: Error) {
        let ns = error as NSError
        // A newer navigation replaced this one; not a failure the user needs to see.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }
        errorMessage = error.localizedDescription
    }

    private func observe() {
        observations = [
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.isLoading = view.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.progress = view.estimatedProgress }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            },
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self, let url = view.url else { return }
                    self.currentURL = url
                    self.address = url.absoluteString
                }
            },
        ]
    }
}

@MainActor
private final class BrowserNavigationDelegate: NSObject, WKNavigationDelegate {
    weak var owner: BrowserSession?

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        owner?.errorMessage = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        owner?.errorMessage = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        owner?.failed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        owner?.failed(error)
    }
}

/// Re-parents the cached web view, the same way the terminal host does.
private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        attach(to: nsView)
    }

    private func attach(to container: NSView) {
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}

/// Turns what the user typed into a URL: `localhost:3000` and bare ports become http, other hosts https.
enum BrowserAddress {
    enum Outcome: Equatable {
        case url(URL)
        case invalid
        case unsupportedScheme

        var url: URL? {
            if case .url(let u) = self { return u }
            return nil
        }
    }

    static func parse(_ input: String) -> Outcome {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(where: \.isWhitespace) else { return .invalid }
        if !s.contains("://") {
            if s.allSatisfy(\.isNumber) { s = "localhost:" + s }
            s = (looksLocal(s) ? "http://" : "https://") + s
        }
        s = s.replacingOccurrences(of: "://0.0.0.0", with: "://localhost")
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else { return .invalid }
        guard scheme == "http" || scheme == "https" else { return .unsupportedScheme }
        guard let host = url.host, !host.isEmpty else { return .invalid }
        return .url(url)
    }

    /// localhost, loopback addresses and anything with an explicit port.
    private static func looksLocal(_ s: String) -> Bool {
        let lower = s.lowercased()
        if lower.hasPrefix("localhost") || lower.hasPrefix("127.") || lower.hasPrefix("0.0.0.0") || lower.hasPrefix("[::1]") {
            return true
        }
        let hostPart = lower.split(separator: "/", maxSplits: 1).first.map(String.init) ?? lower
        guard let colon = hostPart.lastIndex(of: ":") else { return false }
        let port = hostPart[hostPart.index(after: colon)...]
        return !port.isEmpty && port.allSatisfy(\.isNumber)
    }

    /// `localhost:3000/path` without the scheme.
    static func shortLabel(_ url: URL) -> String {
        var s = url.absoluteString
        for prefix in ["http://", "https://"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

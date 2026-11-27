import UIKit
import WebKit

/**
 * Full-screen WKWebView that hosts `/embed.html` and bridges its `agil:*`
 * messages to the plugin.
 *
 * Security:
 *  - only the widget origin and explicit `allowedOrigins` may load;
 *  - outgoing navigation is blocked and handed to the system browser;
 *  - `AgilBridge` only accepts string payloads, which are parsed/sanitized in
 *    JS (`src/bridge.ts`) before reaching host listeners;
 *  - the shim is installed at document start, so `agil:ready` is never missed.
 */
final class AgilCallViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private static let bridgeName = "AgilBridge"

    private let startURL: URL
    private let widgetOrigin: String
    private let allowedOrigins: Set<String>
    private let camera: Bool
    private let microphone: Bool
    private let onMessage: (String) -> Void
    private let onError: (String, String) -> Void

    private var webView: WKWebView?
    /// True once the widget page has proven it is live (`agil:ready`, or another
    /// accepted `agil:*` message if `ready` was already delivered before the
    /// host called `sendAction`/`sendChat`).
    private var pageReady = false
    /// Host commands sent before `pageReady`; bounded so a broken page cannot
    /// grow memory. Flushed in call order on the first accepted widget message.
    private var pendingCommands: [[String: Any]] = []
    private static let maxPendingCommands = 20

    init(
        url: URL,
        origin: String,
        allowedOrigins: [String],
        camera: Bool,
        microphone: Bool,
        onMessage: @escaping (String) -> Void,
        onError: @escaping (String, String) -> Void
    ) {
        self.startURL = url
        self.widgetOrigin = origin
        self.allowedOrigins = Set(allowedOrigins.compactMap { AgilCallViewController.origin(of: $0) })
        self.camera = camera
        self.microphone = microphone
        self.onMessage = onMessage
        self.onError = onError
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.bridgeName)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 8 / 255, green: 13 / 255, blue: 22 / 255, alpha: 1)

        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // Large-room presentation parity with the AGIL iOS SDK view: the widget
        // ships its own mobile viewport and pads with env(safe-area-inset-*).
        configuration.allowsPictureInPictureMediaPlayback = true
        if #available(iOS 15.4, *) {
            configuration.preferences.isElementFullscreenEnabled = true
        }
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile

        let contentController = WKUserContentController()
        contentController.add(self, name: Self.bridgeName)
        contentController.addUserScript(
            WKUserScript(
                source: Self.bootstrapScript(origin: widgetOrigin),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        configuration.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        // The widget owns the only scroll container (participant list); the
        // outer WebView must not bounce, zoom or add safe-area insets of its
        // own (the WebView is pinned to the safe-area layout guide below).
        webView.scrollView.bounces = false
        webView.scrollView.alwaysBounceVertical = false
        webView.scrollView.alwaysBounceHorizontal = false
        webView.scrollView.isDirectionalLockEnabled = true
        webView.scrollView.minimumZoomScale = 1
        webView.scrollView.maximumZoomScale = 1
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        self.webView = webView
        webView.load(URLRequest(url: startURL))
    }

    // MARK: - Theme commands

    func applyTheme(scheme: String?, theme: [String: Any]?) {
        if let scheme {
            post(["type": "agil:scheme", "scheme": scheme])
        }
        if let theme, !theme.isEmpty {
            post(["type": "agil:theme", "theme": theme])
        }
    }

    /// Sends `agil:action` without closing the WebView.
    ///
    /// If the page has not reported readiness yet the command is queued (up to
    /// `maxPendingCommands`) and delivered on the first accepted widget
    /// message, so `openCall()` → `sendAction()` cannot silently lose it.
    func sendAction(_ action: String) {
        enqueueOrPost(["type": "agil:action", "action": action])
    }

    /// Sends `agil:chat-send` without closing the WebView.
    ///
    /// Queued like `sendAction` until the page is ready.
    func sendChat(_ text: String) {
        enqueueOrPost(["type": "agil:chat-send", "text": text])
    }

    private func enqueueOrPost(_ message: [String: Any]) {
        guard pageReady else {
            if pendingCommands.count < Self.maxPendingCommands {
                pendingCommands.append(message)
            }
            return
        }
        post(message)
    }

    /// Delivers commands queued before readiness, preserving their order.
    private func flushPendingCommands() {
        guard pageReady, !pendingCommands.isEmpty else { return }
        let queued = pendingCommands
        pendingCommands.removeAll(keepingCapacity: true)
        for message in queued {
            post(message)
        }
    }

    private func post(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        // U+2028/U+2029 terminate JavaScript source lines.
        let safe = json
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        let script = """
        (function(){try{var p=window.__agilCapacitorPostToPage||window.postMessage;\
        if(typeof p!=="function"){return;}p.call(window,\(safe),window.location.origin);}catch(e){}})();true;
        """
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.bridgeName else { return }
        // The script message handler is global to the WKWebView. The navigation
        // guard may allow additional SSO origins, so bind incoming `agil:*`
        // messages to the widget origin (and the main frame) explicitly.
        guard message.frameInfo.isMainFrame else { return }
        guard let messageOrigin = Self.origin(of: message.frameInfo.securityOrigin),
              messageOrigin == widgetOrigin else { return }
        guard let text = message.body as? String else { return }
        onMessage(text)
        // The first accepted widget message proves the page and its shim are
        // live. Normally that is `agil:ready`; using any accepted `agil:*`
        // message also covers widgets that emit a pre-ready error/state.
        if !pageReady, Self.isWidgetMessage(text) {
            pageReady = true
            flushPendingCommands()
        }
    }

    /// A new document resets readiness: host commands are queued again until
    /// the reloaded widget reports itself live.
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        pageReady = false
    }

    // MARK: - Navigation guard

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "about" {
            let value = url.absoluteString.lowercased()
            if value == "about:blank" || value == "about:srcdoc" {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
            return
        }
        if isAllowed(url) {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if navigationAction.targetFrame?.isMainFrame ?? true,
           scheme == "http" || scheme == "https" {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
        onError("navigation-blocked", "Blocked navigation to \(url.host ?? "an unsupported host")")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        onError("load-failed", Self.describe(error))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onError("load-failed", Self.describe(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onError("render-process-gone", "The WebView content process was terminated")
    }

    // MARK: - Media capture permission (iOS 15+)

    @available(iOS 15.0, *)
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let wantsCamera = type == .camera || type == .cameraAndMicrophone
        let wantsMicrophone = type == .microphone || type == .cameraAndMicrophone
        // WKWebView asks once per capture request and the decision cannot be
        // split for `.cameraAndMicrophone`: deny a combined request if either
        // media type is disabled (the widget may retry audio-only).
        if (wantsCamera && !camera) || (wantsMicrophone && !microphone) {
            decisionHandler(.deny)
            return
        }
        decisionHandler(.grant)
    }

    // MARK: - Helpers

    private func isAllowed(_ url: URL) -> Bool {
        guard let origin = AgilCallViewController.origin(of: url.absoluteString) else {
            return false
        }
        return origin == widgetOrigin || allowedOrigins.contains(origin)
    }

    static func origin(of urlString: String) -> String? {
        AgilOriginNormalizer.normalize(urlString: urlString)
    }

    /// Canonical origin of a `WKFrameInfo.securityOrigin`.
    ///
    /// WebKit reports `port == 0` for the scheme default (`https://host`), so
    /// the normalizer maps 0/443 → `https://host` and 0/80 → `http://host`.
    /// `nil` means the frame origin is unusable and the message must be dropped.
    static func origin(of securityOrigin: WKSecurityOrigin) -> String? {
        AgilOriginNormalizer.normalize(
            securityScheme: securityOrigin.protocol,
            host: securityOrigin.host,
            port: securityOrigin.port
        )
    }

    /// True for a JSON `agil:*` widget message; used only to switch the command
    /// queue from "pending" to "deliver" after the page proves it is live.
    static func isWidgetMessage(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let record = value as? [String: Any],
              let type = record["type"] as? String,
              type.hasPrefix("agil:"),
              type.count <= 64 else {
            return false
        }
        return true
    }

    /// Masks token query values and JWT-looking strings in native error text.
    static func redact(_ text: String) -> String {
        let queryRedacted = text.replacingOccurrences(
            of: "(?i)((?:token|identity_token|id_token|access_token)=)[^&\\s#]+",
            with: "$1redacted",
            options: .regularExpression
        )
        return queryRedacted.replacingOccurrences(
            of: "\\beyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\b",
            with: "redacted",
            options: .regularExpression
        )
    }

    private static func describe(_ error: Error) -> String {
        let text = redact((error as NSError).localizedDescription)
        return text.count > 500 ? String(text.prefix(500)) + "…" : text
    }

    private static func jsString(_ value: String) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: [value]),
            let json = String(data: data, encoding: .utf8),
            json.count >= 2
        else {
            return "\"\""
        }
        return String(json.dropFirst().dropLast())
    }

    private static func bootstrapScript(origin: String) -> String {
        let originLiteral = jsString(origin)
        return """
        (function(){try{
        var w=window;
        if(!w||w.__agilCapacitorBridgeInstalled){return;}
        if(w.location.origin!==\(originLiteral)){return;}
        if(!w.AgilBridge){w.AgilBridge={postMessage:function(message){try{w.webkit.messageHandlers.AgilBridge.postMessage(typeof message==="string"?message:JSON.stringify(message));}catch(e){}}};}
        var channel=w.AgilBridge;
        if(!channel||typeof channel.postMessage!=="function"){return;}
        var original=w.parent.postMessage;
        if(typeof original!=="function"){return;}
        var forward=function(message,targetOrigin){
        try{channel.postMessage(typeof message==="string"?message:JSON.stringify(message));}catch(e){}
        try{return original.call(w.parent,message,targetOrigin||w.location.origin);}catch(e){}
        };
        var installed=false;
        try{w.parent.postMessage=forward;installed=w.parent.postMessage===forward;}catch(e){}
        if(!installed){try{Object.defineProperty(w.parent,"postMessage",{value:forward,writable:true,configurable:true});installed=w.parent.postMessage===forward;}catch(e2){}}
        if(installed){w.__agilCapacitorPostToPage=original;w.__agilCapacitorBridgeInstalled=true;}
        }catch(e){}})();true;
        """
    }
}

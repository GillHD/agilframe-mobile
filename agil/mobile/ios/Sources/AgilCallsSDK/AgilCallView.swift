import UIKit
import WebKit

/// Media capture capabilities the WebView may grant to the widget.
public struct AgilMediaCapture: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let camera = AgilMediaCapture(rawValue: 1 << 0)
    public static let microphone = AgilMediaCapture(rawValue: 1 << 1)
    public static let cameraAndMicrophone: AgilMediaCapture = [.camera, .microphone]
    public static let none: AgilMediaCapture = []
}

/// Delegate for host apps that prefer delegation to closures. Every method has
/// a default implementation.
public protocol AgilCallViewDelegate: AnyObject {
    func agilCallView(_ callView: AgilCallView, didReceive event: AgilCallEvent)
    func agilCallView(_ callView: AgilCallView, didFailWith failure: AgilCallFailure)
    func agilCallView(_ callView: AgilCallView, didBlockNavigationTo origin: String)
    func agilCallView(_ callView: AgilCallView, didChangeState state: AgilCallView.State)
}

public extension AgilCallViewDelegate {
    func agilCallView(_ callView: AgilCallView, didReceive event: AgilCallEvent) {}
    func agilCallView(_ callView: AgilCallView, didFailWith failure: AgilCallFailure) {}
    func agilCallView(_ callView: AgilCallView, didBlockNavigationTo origin: String) {}
    func agilCallView(_ callView: AgilCallView, didChangeState state: AgilCallView.State) {}
}

/// Native UIView that hosts the hosted `/embed.html` widget in a WKWebView.
///
/// Responsibilities (tier-1 module; media/chat/theme stay in the widget):
///  - build and load the validated embed URL;
///  - inline media playback + autoplay and camera/microphone capture policy;
///  - inject `window.AgilBridge` at document start and forward `agil:*`
///    messages to typed events; forwarded messages carry a per-load nonce and
///    are accepted only from the widget origin's main frame;
///  - expose mute/camera/chat/theme/leave commands (queued until `agil:ready`);
///  - enforce the exact-origin navigation allowlist.
///
/// Networking, WebRTC, chat rendering and theming are performed by the hosted
/// widget on the AgilFrame origin. The view never logs and never places tokens
/// in JavaScript source: the token exists only in the page URL inside the
/// WebView.
///
/// Use it from the main thread. It loads automatically when added to a window;
/// call ``loadIfNeeded()`` explicitly to preload.
public final class AgilCallView: UIView {
    /// Lifecycle of the view; `ready` means the widget handshake completed.
    public enum State: String, Equatable, Sendable {
        case idle
        case loading
        case ready
        case joined
        case left
        case failed
        case destroyed
    }

    /// Validated configuration. Replace it with ``update(configuration:)``.
    public private(set) var configuration: AgilCallConfiguration
    /// Current lifecycle state.
    public private(set) var state: State = .idle
    /// `true` after the widget answered `agil:ready`/`agil:pong`.
    public private(set) var isReady: Bool = false

    public weak var delegate: AgilCallViewDelegate?
    /// Convenience closure alternative to ``delegate``.
    public var onEvent: ((AgilCallEvent) -> Void)?
    /// Called for every failure (also delivered as ``AgilCallEvent/error(_:)``).
    public var onFailure: ((AgilCallFailure) -> Void)?
    /// Called with the blocked origin (never the full URL).
    public var onBlockedNavigation: ((String) -> Void)?
    public var onStateChange: ((State) -> Void)?

    /// Seconds to wait for `agil:ready` before reporting a bridge timeout.
    public var readyTimeout: TimeInterval = 20
    /// Media capture allowed through `WKUIDelegate` (iOS 15+). The app still
    /// needs the matching `Info.plist` usage strings.
    public var allowedMediaCapture: AgilMediaCapture = .cameraAndMicrophone
    /// Pin the WebView to the safe area. Default `false` for a full-bleed call
    /// surface; the widget already pads its controls with
    /// `env(safe-area-inset-*)`.
    public var respectsSafeArea: Bool = false {
        didSet {
            updateWebViewConstraints()
        }
    }

    private static let callBackground = UIColor(red: 8 / 255, green: 13 / 255, blue: 22 / 255, alpha: 1)

    private let providedWebViewConfiguration: WKWebViewConfiguration?
    private let messageProxy = AgilScriptMessageProxy()
    private var webView: WKWebView?
    private var bridgeNonce = AgilBridge.makeNonce()
    private var shimUserScript: WKUserScript?
    private var pendingScripts: [String] = []
    private var pingTimer: Timer?
    private var readyDeadline: DispatchWorkItem?
    private var readyTimedOut = false
    private var didStartLoading = false
    private var didReportBridgeError = false
    private var edgeConstraints: [NSLayoutConstraint] = []
    /// Large-room bridge digests: one bounded participant snapshot per load,
    /// then deltas; connection transitions are deduplicated.
    private var participantDigest = AgilParticipantDigest()
    private var connectionDigest = AgilConnectionDigest()

    public init(
        configuration: AgilCallConfiguration,
        webViewConfiguration: WKWebViewConfiguration? = nil
    ) {
        self.configuration = configuration
        self.providedWebViewConfiguration = webViewConfiguration
        super.init(frame: .zero)
        backgroundColor = Self.callBackground
        messageProxy.onMessage = { [weak self] message in
            self?.handleScriptMessage(message)
        }
        setUpWebView()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported; create AgilCallView with a configuration")
    }

    deinit {
        readyDeadline?.cancel()
        pingTimer?.invalidate()
        messageProxy.onMessage = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: AgilBridge.bridgeName
        )
    }

    // MARK: - Lifecycle

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            loadIfNeeded()
        }
    }

    /// Loads the widget once. Safe to call repeatedly.
    public func loadIfNeeded() {
        guard !didStartLoading, let webView = webView else {
            return
        }
        do {
            let url = try AgilWidgetURL.build(configuration)
            didStartLoading = true
            readyTimedOut = false
            didReportBridgeError = false
            isReady = false
            participantDigest.reset()
            connectionDigest.reset()
            // Rotate the bridge nonce for every SDK-initiated load. Messages
            // from a previous page (or from a page that only calls the handler
            // directly) are rejected after this point.
            installShim(
                on: webView.configuration.userContentController,
                rotateNonce: true
            )
            setState(.loading)
            startWatchdog()
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 30
            webView.load(request)
        } catch {
            report(AgilCallFailure(
                code: .invalidConfiguration,
                message: "The AgilFrame URL could not be built",
                fatal: true
            ))
        }
    }

    /// Reloads the same room (for example after a transient network failure).
    public func reload() {
        guard webView != nil else {
            return
        }
        stopWatchdog()
        webView?.stopLoading()
        pendingScripts.removeAll()
        didStartLoading = false
        readyTimedOut = false
        didReportBridgeError = false
        isReady = false
        loadIfNeeded()
    }

    /**
     * Explicit host reconnect: announces the transition, then reloads with the
     * same server/room/join token/identity token. The bridge nonce is rotated
     * for the new document and the participant digest restarts with one
     * bounded snapshot.
     */
    public func reconnect() {
        deliver(.connection(AgilConnectionUpdate(
            state: .connecting,
            previous: connectionDigest.currentState ?? .reconnecting,
            reconnecting: true
        )))
        reload()
    }

    /// Replaces the configuration and reloads the widget. A no-op when equal.
    public func update(configuration newConfiguration: AgilCallConfiguration) {
        guard newConfiguration != configuration else {
            return
        }
        tearDownWebView()
        configuration = newConfiguration
        resetForLoad()
        setUpWebView()
        if window != nil {
            loadIfNeeded()
        }
    }

    /// Tears down the WebView, queue and timers. The view cannot be reused
    /// afterwards; create a new ``AgilCallView`` to start another call.
    public func destroy() {
        stopWatchdog()
        pendingScripts.removeAll()
        isReady = false
        didStartLoading = false
        tearDownWebView()
        setState(.destroyed)
    }

    /// Removes persistent WKWebView data for the whole app.
    ///
    /// Call it on logout if you pass a persistent `WKWebViewConfiguration` or if
    /// the same device is shared between accounts. The default call view already
    /// uses an ephemeral data store, so this is only needed for custom
    /// configurations.
    public static func clearWebsiteData(completion: (() -> Void)? = nil) {
        let store = WKWebsiteDataStore.default()
        store.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) {
            if let completion = completion {
                DispatchQueue.main.async {
                    completion()
                }
            }
        }
    }

    // MARK: - Commands

    /// Sends a typed command. Commands sent before `agil:ready` are queued
    /// (bounded) and flushed by the handshake.
    public func send(_ command: AgilCallCommand) throws {
        guard webView != nil else {
            throw AgilBridgeError.notLoaded
        }
        let script = try AgilBridge.hostMessageScript(command)
        if isReady {
            evaluate(script)
            return
        }
        guard pendingScripts.count < AgilBridge.maxQueuedCommands else {
            throw AgilBridgeError.queueFull
        }
        pendingScripts.append(script)
    }

    public func toggleMicrophone() {
        enqueue(.action(.toggleMic))
    }

    public func toggleCamera() {
        enqueue(.action(.toggleCamera))
    }

    public func toggleChat() {
        enqueue(.action(.toggleChat))
    }

    public func leave() {
        enqueue(.action(.leave))
    }

    /// Asks the widget for Document Picture-in-Picture. Availability depends on
    /// WKWebView; the widget reports `action-denied` when unsupported.
    public func requestPictureInPicture() {
        enqueue(.action(.pip))
    }

    /// Asks the widget to move the call into a new tab. Unsafe popups are
    /// blocked by ``WKUIDelegate`` and are reported as `navigation-blocked`.
    public func openInNewTab() {
        enqueue(.action(.newtab))
    }

    public func setTheme(_ scheme: AgilThemeScheme) {
        enqueue(.theme(scheme))
    }

    /// Applies a partial theme patch (`agil:theme`). Values are sanitized and
    /// bounded; tokens must never be placed in a theme.
    public func setThemePatch(_ patch: [String: AgilJSONValue]) throws {
        try send(.themePatch(patch))
    }

    /// Sends a chat message (`agil:chat-send`). Throws for empty/oversized text.
    public func sendChatMessage(_ text: String) throws {
        try send(.sendChat(text))
    }

    private func enqueue(_ command: AgilCallCommand) {
        do {
            try send(command)
        } catch {
            reportBridgeErrorOnce()
        }
    }

    // MARK: - WebView setup

    private func setUpWebView() {
        let webConfiguration = providedWebViewConfiguration ?? WKWebViewConfiguration()
        if providedWebViewConfiguration == nil {
            // Ephemeral store: the token-bearing URL does not get persisted in
            // disk cache/cookies by default.
            webConfiguration.websiteDataStore = .nonPersistent()
        }
        webConfiguration.allowsInlineMediaPlayback = true
        webConfiguration.mediaTypesRequiringUserActionForPlayback = []
        webConfiguration.defaultWebpagePreferences.allowsContentJavaScript = true
        webConfiguration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Large-room presentation: allow the widget's DOM fullscreen and PiP so
        // a 200-participant gallery can expand without leaving the WebView.
        webConfiguration.allowsPictureInPictureMediaPlayback = true
        if #available(iOS 15.4, *) {
            webConfiguration.preferences.isElementFullscreenEnabled = true
        }
        // The widget ships its own mobile viewport; keep the WebView in mobile
        // content mode so `width=device-width` is honoured on iPad too.
        if #available(iOS 13.0, *) {
            webConfiguration.defaultWebpagePreferences.preferredContentMode = .mobile
        }

        let controller = webConfiguration.userContentController
        controller.add(messageProxy, name: AgilBridge.bridgeName)
        installShim(on: controller, rotateNonce: true)

        let webView = WKWebView(frame: .zero, configuration: webConfiguration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        // The widget owns the only scroll container (participant list); the
        // outer WebView must not bounce, zoom or add safe-area insets of its
        // own (respectsSafeArea handles the latter).
        webView.scrollView.bounces = false
        webView.scrollView.alwaysBounceVertical = false
        webView.scrollView.alwaysBounceHorizontal = false
        webView.scrollView.isDirectionalLockEnabled = true
        webView.scrollView.minimumZoomScale = 1
        webView.scrollView.maximumZoomScale = 1
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = true
        webView.backgroundColor = Self.callBackground
        webView.scrollView.backgroundColor = Self.callBackground
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        self.webView = webView
        participantDigest = AgilParticipantDigest(
            limits: AgilLargeRoomLimits(maxParticipants: configuration.maxParticipants)
        )
        connectionDigest.reset()
        updateWebViewConstraints()
    }

    /// Installs (or replaces) the document-start shim with the current nonce.
    ///
    /// The nonce is secret to the widget-origin document: only the shim closure
    /// can wrap a message with it, so a direct
    /// `webkit.messageHandlers.AgilBridge.postMessage(...)` from any other page
    /// is rejected by ``AgilBridge/parseMessage(_:nonce:)``.
    private func installShim(on controller: WKUserContentController, rotateNonce: Bool) {
        if rotateNonce {
            bridgeNonce = AgilBridge.makeNonce()
        }
        if let previous = shimUserScript {
            controller.removeUserScript(previous)
        }
        let script = WKUserScript(
            source: AgilBridge.shimScript(
                widgetOrigin: configuration.widgetOrigin,
                nonce: bridgeNonce
            ),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        controller.addUserScript(script)
        shimUserScript = script
    }

    private func updateWebViewConstraints() {
        guard let webView = webView else {
            return
        }
        NSLayoutConstraint.deactivate(edgeConstraints)
        let constraints: [NSLayoutConstraint]
        if respectsSafeArea {
            constraints = [
                webView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
                webView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
                webView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor)
            ]
        } else {
            constraints = [
                webView.leadingAnchor.constraint(equalTo: leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: trailingAnchor),
                webView.topAnchor.constraint(equalTo: topAnchor),
                webView.bottomAnchor.constraint(equalTo: bottomAnchor)
            ]
        }
        NSLayoutConstraint.activate(constraints)
        edgeConstraints = constraints
    }

    private func resetForLoad() {
        stopWatchdog()
        pendingScripts.removeAll()
        didStartLoading = false
        readyTimedOut = false
        didReportBridgeError = false
        isReady = false
        setState(.idle)
    }

    private func tearDownWebView() {
        guard let webView = webView else {
            return
        }
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: AgilBridge.bridgeName)
        if let script = shimUserScript {
            controller.removeUserScript(script)
        }
        shimUserScript = nil
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
        webView.removeFromSuperview()
        self.webView = nil
    }

    // MARK: - Bridge

    /// Origins allowed for navigation only (the widget origin plus
    /// `allowedOrigins`). Native bridge messages are stricter: widget origin
    /// only, see ``handleScriptMessage(_:)``.
    private var navigationOrigins: Set<String> {
        return Set([configuration.widgetOrigin] + configuration.allowedOrigins)
    }

    private func handleScriptMessage(_ message: WKScriptMessage) {
        guard message.name == AgilBridge.bridgeName, message.frameInfo.isMainFrame else {
            return
        }
        // The shim only runs on the widget origin, so native messages are
        // trusted only from that frame. `allowedOrigins` expands navigation,
        // not the bridge trust boundary: an allowlisted SSO page cannot spoof
        // `agil:*` by calling the handler directly (the nonce is checked too).
        let securityOrigin = message.frameInfo.securityOrigin
        guard let frameOrigin = AgilValidation.canonicalOrigin(
            scheme: securityOrigin.`protocol`,
            host: securityOrigin.host,
            port: securityOrigin.port > 0 ? securityOrigin.port : nil
        ), frameOrigin == configuration.widgetOrigin else {
            return
        }
        switch AgilBridge.parseMessage(message.body, nonce: bridgeNonce) {
        case .event(let event):
            handle(event)
        case .pong:
            markReady()
        case .ignored:
            break
        }
    }

    private func handle(_ event: AgilCallEvent) {
        switch event {
        case .ready:
            markReady()
            setState(.ready)
            deliver(event)
        case .joined:
            setState(.joined)
            deliver(event)
        case .left:
            setState(.left)
            deliver(event)
        case .error(let failure):
            report(failure)
        case .state(let snapshot):
            let update = participantDigest.apply(
                participantIds: snapshot.hasParticipantIds ? snapshot.participantIds : nil,
                count: snapshot.participants
            )
            let connection = connectionDigest.apply(
                state: snapshot.connectionState,
                attempt: nil,
                delayMs: nil
            )
            if let connection {
                deliver(.connection(connection))
            }
            // The compact state never carries ids; the bounded set is delivered
            // once through the participants snapshot.
            let compact = snapshot.compacting(participantUpdate: update)
            deliver(.state(compact))
            if let update {
                deliver(.participants(update))
            }
        case .participants, .connection:
            deliver(event)
        case .chat, .minimized, .fullscreen:
            deliver(event)
        case .event(let name, let payload):
            if name == "connection-state" || name == "connection-changed" {
                let fields = payload?.objectValue ?? [:]
                let connection = connectionDigest.apply(
                    state: fields["connection"]?.stringValue ?? fields["connectionState"]?.stringValue,
                    attempt: fields["attempt"]?.intValue ?? fields["reconnectAttempt"]?.intValue,
                    delayMs: fields["delayMs"]?.intValue ?? fields["delay"]?.intValue
                )
                if let connection {
                    deliver(.connection(connection))
                }
            }
            deliver(event)
        }
    }

    private func markReady() {
        guard !isReady else {
            return
        }
        isReady = true
        stopWatchdog()
        let queued = pendingScripts
        pendingScripts.removeAll()
        for script in queued {
            evaluate(script)
        }
    }

    private func deliver(_ event: AgilCallEvent) {
        onEvent?(event)
        delegate?.agilCallView(self, didReceive: event)
    }

    private func report(_ failure: AgilCallFailure) {
        if failure.fatal {
            stopWatchdog()
            setState(.failed)
        }
        let event = AgilCallEvent.error(failure)
        onEvent?(event)
        onFailure?(failure)
        delegate?.agilCallView(self, didReceive: event)
        delegate?.agilCallView(self, didFailWith: failure)
    }

    private func reportBridgeErrorOnce() {
        guard !didReportBridgeError else {
            return
        }
        didReportBridgeError = true
        report(AgilCallFailure(
            code: .bridgeError,
            message: "The AgilFrame bridge is unavailable",
            fatal: false
        ))
    }

    private func setState(_ newState: State) {
        guard state != newState else {
            return
        }
        state = newState
        onStateChange?(newState)
        delegate?.agilCallView(self, didChangeState: newState)
    }

    // MARK: - Watchdog and scripts

    private func startWatchdog() {
        stopWatchdog()
        readyTimedOut = false
        isReady = false
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.ping()
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer

        let deadline = DispatchWorkItem { [weak self] in
            guard let self = self, !self.isReady else {
                return
            }
            self.readyTimedOut = true
            self.stopWatchdog()
            self.report(AgilCallFailure(
                code: .bridgeTimeout,
                message: "The AgilFrame widget did not become ready in time",
                fatal: true
            ))
        }
        readyDeadline = deadline
        if readyTimeout > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + readyTimeout, execute: deadline)
        }
    }

    private func stopWatchdog() {
        pingTimer?.invalidate()
        pingTimer = nil
        readyDeadline?.cancel()
        readyDeadline = nil
    }

    private func ping() {
        guard !isReady, !readyTimedOut, webView != nil else {
            return
        }
        if let script = try? AgilBridge.hostMessageScript(.ping) {
            evaluate(script)
        }
    }

    private func evaluate(_ script: String) {
        webView?.evaluateJavaScript(script) { [weak self] _, error in
            if error != nil {
                self?.reportBridgeErrorOnce()
            }
        }
    }

    // MARK: - Failures

    private func reportLoadFailure(_ error: Error) {
        let nsError = error as NSError
        // `stopLoading()` (reload/destroy) surfaces as NSURLErrorCancelled and is
        // not a user-visible failure.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return
        }
        stopWatchdog()
        let redacted = AgilRedaction.redactTokenText(nsError.localizedDescription)
        let trimmed = redacted.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = trimmed.isEmpty
            ? "The AgilFrame page failed to load"
            : (trimmed.count > 300 ? String(trimmed.prefix(299)) + "…" : trimmed)
        report(AgilCallFailure(code: .loadFailed, message: message, fatal: true))
    }

    private func handleBlockedNavigation(_ url: URL) {
        let origin = AgilValidation.origin(of: url) ?? "an unsupported URL"
        onBlockedNavigation?(origin)
        delegate?.agilCallView(self, didBlockNavigationTo: origin)
        report(AgilCallFailure(
            code: .navigationBlocked,
            message: "Blocked navigation to \(origin)",
            fatal: false
        ))
    }
}

// MARK: - WKNavigationDelegate / WKUIDelegate

extension AgilCallView: WKNavigationDelegate, WKUIDelegate {
    public func webView(
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
            decisionHandler(value == "about:blank" || value == "about:srcdoc" ? .allow : .cancel)
            return
        }
        if AgilWidgetURL.isAllowedNavigation(
            url,
            allowedOrigins: navigationOrigins,
            allowsInsecureHTTP: configuration.allowsInsecureHTTP
        ) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            handleBlockedNavigation(url)
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Idempotent retry: covers a document replacement that happened after
        // the document-start injection. Reuses the current nonce so messages
        // from this document stay valid.
        if let source = shimUserScript?.source {
            webView.evaluateJavaScript(source, completionHandler: nil)
        }
    }

    public func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        reportLoadFailure(error)
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        reportLoadFailure(error)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        stopWatchdog()
        report(AgilCallFailure(
            code: .renderProcessGone,
            message: "The AgilFrame WebView process was terminated",
            fatal: true
        ))
    }

    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url,
           !AgilWidgetURL.isAllowedNavigation(
               url,
               allowedOrigins: navigationOrigins,
               allowsInsecureHTTP: configuration.allowsInsecureHTTP
           ) {
            handleBlockedNavigation(url)
        }
        // Popups are never opened; the call stays in this WebView.
        return nil
    }

    @available(iOS 15.0, *)
    public func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let canonical = AgilValidation.canonicalOrigin(
            scheme: origin.`protocol`,
            host: origin.host,
            port: origin.port > 0 ? origin.port : nil
        )
        // Media capture is granted to the hosted widget origin only. Extra
        // `allowedOrigins` are for messages/navigation, not camera access.
        guard let canonical = canonical, canonical == configuration.widgetOrigin else {
            decisionHandler(.deny)
            report(AgilCallFailure(
                code: .permissionDenied,
                message: "Media capture was denied for an untrusted origin",
                fatal: false
            ))
            return
        }
        let allowed: Bool
        switch type {
        case .camera:
            allowed = allowedMediaCapture.contains(.camera)
        case .microphone:
            allowed = allowedMediaCapture.contains(.microphone)
        case .cameraAndMicrophone:
            allowed = allowedMediaCapture.contains(.camera)
                && allowedMediaCapture.contains(.microphone)
        @unknown default:
            allowed = false
        }
        if allowed {
            decisionHandler(.grant)
        } else {
            decisionHandler(.deny)
            report(AgilCallFailure(
                code: .permissionDenied,
                message: "Media capture is disabled for this call",
                fatal: false
            ))
        }
    }
}

// MARK: - Script message proxy

/// Breaks the `WKUserContentController` -> handler -> view retain cycle.
private final class AgilScriptMessageProxy: NSObject, WKScriptMessageHandler {
    var onMessage: ((WKScriptMessage) -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        onMessage?(message)
    }
}

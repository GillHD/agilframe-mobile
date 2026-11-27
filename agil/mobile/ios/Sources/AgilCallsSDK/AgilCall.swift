import SwiftUI
import WebKit

/// SwiftUI wrapper for ``AgilCallView``.
///
/// The configuration is validated by its initializer; the view loads the hosted
/// widget when SwiftUI mounts it. If `configuration` changes, the underlying
/// WebView is rebuilt and reloaded. A custom `webViewConfiguration` is applied
/// only when the view is created, not on later updates.
///
/// ```swift
/// struct CallScreen: View {
///     let configuration: AgilCallConfiguration
///
///     var body: some View {
///         AgilCall(configuration: configuration) { event in
///             if case .joined = event { print("joined") }
///         }
///         .ignoresSafeArea()
///     }
/// }
/// ```
public struct AgilCall: UIViewRepresentable {
    public var configuration: AgilCallConfiguration
    public var webViewConfiguration: WKWebViewConfiguration?
    /// Pin the WebView to the safe area (default `false`, full-bleed).
    public var respectsSafeArea: Bool
    /// Media capture to allow through `WKUIDelegate` (iOS 15+).
    public var allowsMediaCapture: AgilMediaCapture
    public var onEvent: ((AgilCallEvent) -> Void)?
    public var onFailure: ((AgilCallFailure) -> Void)?
    public var onBlockedNavigation: ((String) -> Void)?
    public var onStateChange: ((AgilCallView.State) -> Void)?
    /// Receives the created view so the host can call commands
    /// (`toggleMicrophone()`, `leave()`, ...).
    public var onViewReady: ((AgilCallView) -> Void)?

    public init(
        configuration: AgilCallConfiguration,
        webViewConfiguration: WKWebViewConfiguration? = nil,
        respectsSafeArea: Bool = false,
        allowsMediaCapture: AgilMediaCapture = .cameraAndMicrophone,
        onViewReady: ((AgilCallView) -> Void)? = nil,
        onStateChange: ((AgilCallView.State) -> Void)? = nil,
        onBlockedNavigation: ((String) -> Void)? = nil,
        onFailure: ((AgilCallFailure) -> Void)? = nil,
        onEvent: ((AgilCallEvent) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.webViewConfiguration = webViewConfiguration
        self.respectsSafeArea = respectsSafeArea
        self.allowsMediaCapture = allowsMediaCapture
        self.onEvent = onEvent
        self.onFailure = onFailure
        self.onBlockedNavigation = onBlockedNavigation
        self.onStateChange = onStateChange
        self.onViewReady = onViewReady
    }

    public func makeUIView(context: Context) -> AgilCallView {
        let view = AgilCallView(
            configuration: configuration,
            webViewConfiguration: webViewConfiguration
        )
        view.respectsSafeArea = respectsSafeArea
        view.allowedMediaCapture = allowsMediaCapture
        let coordinator = context.coordinator
        view.onEvent = { event in
            coordinator.parent.onEvent?(event)
        }
        view.onFailure = { failure in
            coordinator.parent.onFailure?(failure)
        }
        view.onBlockedNavigation = { origin in
            coordinator.parent.onBlockedNavigation?(origin)
        }
        view.onStateChange = { state in
            coordinator.parent.onStateChange?(state)
        }
        onViewReady?(view)
        view.loadIfNeeded()
        return view
    }

    public func updateUIView(_ uiView: AgilCallView, context: Context) {
        context.coordinator.parent = self
        uiView.respectsSafeArea = respectsSafeArea
        uiView.allowedMediaCapture = allowsMediaCapture
        if uiView.configuration != configuration {
            uiView.update(configuration: configuration)
        }
    }

    public func makeCoordinator() -> Coordinator {
        return Coordinator(parent: self)
    }

    public final class Coordinator {
        var parent: AgilCall

        init(parent: AgilCall) {
            self.parent = parent
        }
    }
}

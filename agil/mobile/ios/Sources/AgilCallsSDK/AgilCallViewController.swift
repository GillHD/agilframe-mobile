import UIKit
import WebKit

/// Full-screen UIKit container for ``AgilCallView``.
///
/// Presents with `.fullScreen`, hides the status bar/home indicator, and
/// optionally dismisses itself when the widget reports `left`.
///
/// ```swift
/// let controller = AgilCallViewController(configuration: configuration)
/// controller.dismissOnLeave = true
/// controller.present(from: self)
/// ```
public final class AgilCallViewController: UIViewController {
    public let callView: AgilCallView
    /// Dismiss the controller automatically when the widget emits `left`.
    public var dismissOnLeave: Bool = false
    /// Forwarded events (in addition to ``callView`` callbacks).
    public var onEvent: ((AgilCallEvent) -> Void)?
    /// Called after the controller has been dismissed by ``close(animated:)`` or
    /// ``dismissOnLeave``.
    public var onClose: (() -> Void)?

    private var hasRequestedClose = false

    public init(
        configuration: AgilCallConfiguration,
        webViewConfiguration: WKWebViewConfiguration? = nil
    ) {
        self.callView = AgilCallView(
            configuration: configuration,
            webViewConfiguration: webViewConfiguration
        )
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        callView.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported; create AgilCallViewController with a configuration")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        callView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(callView)
        NSLayoutConstraint.activate([
            callView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            callView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            callView.topAnchor.constraint(equalTo: view.topAnchor),
            callView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        callView.loadIfNeeded()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || isMovingFromParent {
            callView.destroy()
        }
    }

    /// Presents the call full screen from any view controller.
    public func present(
        from presenter: UIViewController,
        animated: Bool = true,
        completion: (() -> Void)? = nil
    ) {
        presenter.present(self, animated: animated, completion: completion)
    }

    /// Leaves the call and dismisses the controller.
    public func close(animated: Bool = true) {
        callView.leave()
        dismissIfPresented(animated: animated)
    }

    private func handle(_ event: AgilCallEvent) {
        onEvent?(event)
        if case .left = event, dismissOnLeave {
            dismissIfPresented(animated: true)
        }
    }

    private func dismissIfPresented(animated: Bool) {
        guard !hasRequestedClose else {
            return
        }
        hasRequestedClose = true
        let isPresented = presentingViewController != nil
            || navigationController?.presentingViewController != nil
        if isPresented {
            dismiss(animated: animated) { [weak self] in
                self?.onClose?()
            }
        } else {
            onClose?()
        }
    }

    public override var prefersStatusBarHidden: Bool {
        return true
    }

    public override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    public override var prefersHomeIndicatorAutoHidden: Bool {
        return true
    }
}

import Foundation
import Capacitor
import AVFoundation
import UIKit

/**
 * Native shell for the hosted AgilFrame widget (`/embed.html`).
 *
 * The plugin owns presentation and permissions only: media, chat and themes run
 * inside the WKWebView. Widget messages are forwarded to JS as raw JSON on the
 * `callMessage` channel and parsed/sanitized by `src/bridge.ts`.
 */
@objc(AgilCallsPlugin)
public class AgilCallsPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "AgilCallsPlugin"
    public let jsName = "AgilCalls"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "openCall", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "close", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "isSupported", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setTheme", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "sendAction", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "sendChat", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "checkPermissions", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "requestPermissions", returnType: CAPPluginReturnPromise)
    ]

    private var callController: AgilCallViewController?
    private var currentCallId: String?

    // MARK: - Calls

    @objc func openCall(_ call: CAPPluginCall) {
        guard let urlString = call.getString("url"), let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            call.reject("openCall requires an http(s) widget URL")
            return
        }

        let presentation = call.getString("presentation") ?? "auto"
        if presentation == "external" {
            DispatchQueue.main.async {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                call.resolve(["callId": UUID().uuidString, "mode": "external"])
            }
            return
        }

        guard let hostController = bridge?.viewController else {
            if presentation == "auto" {
                DispatchQueue.main.async {
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                    call.resolve(["callId": UUID().uuidString, "mode": "external"])
                }
                return
            }
            call.reject("No host view controller; open the call externally instead")
            return
        }

        guard let origin = AgilCallViewController.origin(of: url.absoluteString) else {
            call.reject("openCall received an unsupported URL origin")
            return
        }

        let allowedOrigins = call.getArray("allowedOrigins", String.self) ?? []
        let permissions = call.getObject("permissions") ?? [:]
        let camera = (permissions["camera"] as? Bool) ?? true
        let microphone = (permissions["microphone"] as? Bool) ?? true
        let callId = UUID().uuidString

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                call.reject("The AgilFrame plugin was deallocated")
                return
            }
            self.callController?.dismiss(animated: false)
            let controller = AgilCallViewController(
                url: url,
                origin: origin,
                allowedOrigins: allowedOrigins,
                camera: camera,
                microphone: microphone,
                onMessage: { [weak self] raw in
                    self?.notifyListeners("callMessage", data: ["raw": raw])
                },
                onError: { [weak self] code, message in
                    guard let self else { return }
                    let payload: [String: Any] = [
                        "type": "agil:event",
                        "event": "error",
                        "payload": ["code": code, "message": message]
                    ]
                    if let data = try? JSONSerialization.data(withJSONObject: payload),
                       let raw = String(data: data, encoding: .utf8) {
                        self.notifyListeners("callMessage", data: ["raw": raw])
                    }
                }
            )
            controller.modalPresentationStyle = .fullScreen
            hostController.present(controller, animated: true)
            self.callController = controller
            self.currentCallId = callId
            call.resolve(["callId": callId, "mode": "in-app"])
        }
    }

    @objc func close(_ call: CAPPluginCall) {
        DispatchQueue.main.async { [weak self] in
            self?.callController?.dismiss(animated: true)
            self?.callController = nil
            self?.currentCallId = nil
            call.resolve()
        }
    }

    @objc func isSupported(_ call: CAPPluginCall) {
        let inApp = bridge?.viewController != nil
        var result: [String: Any] = ["supported": true, "inAppWebView": inApp]
        if !inApp {
            result["reason"] = "no host view controller; calls open in the system browser"
        }
        call.resolve(result)
    }

    @objc func setTheme(_ call: CAPPluginCall) {
        let scheme = call.getString("scheme")
        let theme = call.getObject("theme")
        if scheme == nil && theme == nil {
            call.resolve()
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.callController?.applyTheme(scheme: scheme, theme: theme)
            call.resolve()
        }
    }

    @objc func sendAction(_ call: CAPPluginCall) {
        let action = (call.getString("action") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !action.isEmpty, action.count <= 64 else {
            call.reject("sendAction requires a widget action")
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let controller = self?.callController else {
                call.reject("No AgilFrame WebView is open")
                return
            }
            controller.sendAction(action)
            call.resolve()
        }
    }

    @objc func sendChat(_ call: CAPPluginCall) {
        let text = call.getString("text") ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            call.reject("sendChat requires non-empty text")
            return
        }
        let capped = String(text.prefix(4000))
        DispatchQueue.main.async { [weak self] in
            guard let controller = self?.callController else {
                call.reject("No AgilFrame WebView is open")
                return
            }
            controller.sendChat(capped)
            call.resolve()
        }
    }

    // MARK: - Permissions

    @objc public override func checkPermissions(_ call: CAPPluginCall) {
        let camera = AgilCallsPlugin.status(AVCaptureDevice.authorizationStatus(for: .video))
        let microphone = AgilCallsPlugin.status(AVCaptureDevice.authorizationStatus(for: .audio))
        call.resolve(AgilCallsPlugin.report(camera: camera, microphone: microphone))
    }

    @objc public override func requestPermissions(_ call: CAPPluginCall) {
        AVCaptureDevice.requestAccess(for: .video) { cameraGranted in
            let camera = cameraGranted ? "granted" : "denied"
            AVCaptureDevice.requestAccess(for: .audio) { microphoneGranted in
                let microphone = microphoneGranted ? "granted" : "denied"
                DispatchQueue.main.async {
                    call.resolve(AgilCallsPlugin.report(camera: camera, microphone: microphone))
                }
            }
        }
    }

    private static func status(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "granted"
        case .denied:
            return "denied"
        case .restricted:
            return "blocked"
        case .notDetermined:
            return "prompt"
        @unknown default:
            return "unavailable"
        }
    }

    private static func report(camera: String, microphone: String) -> [String: Any] {
        return [
            "camera": camera,
            "microphone": microphone,
            "settingsRequired": camera == "denied" || camera == "blocked" || microphone == "denied" || microphone == "blocked"
        ]
    }
}

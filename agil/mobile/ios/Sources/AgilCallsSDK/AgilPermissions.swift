import AVFoundation
import Foundation

/// Normalized AVFoundation authorization state.
public enum AgilMediaPermissionStatus: String, Equatable, Sendable {
    case granted
    case denied
    case restricted
    case undetermined
    case unavailable
}

/// Camera + microphone permission snapshot.
public struct AgilCallPermissionStatus: Equatable, Sendable {
    public let camera: AgilMediaPermissionStatus
    public let microphone: AgilMediaPermissionStatus

    public init(camera: AgilMediaPermissionStatus, microphone: AgilMediaPermissionStatus) {
        self.camera = camera
        self.microphone = microphone
    }

    /// `true` when at least one capability is blocked and the user must open
    /// Settings.
    public var settingsRequired: Bool {
        return camera == .denied || camera == .restricted
            || microphone == .denied || microphone == .restricted
    }

    public var cameraGranted: Bool {
        return camera == .granted
    }

    public var microphoneGranted: Bool {
        return microphone == .granted
    }
}

/// Thin AVFoundation preflight helper for WKWebView media capture.
///
/// WKWebView shows its own site permission prompt, but iOS also needs the
/// app-level camera/microphone authorization. Asking early (for example on the
/// call screen) avoids a black video tile after the widget's `getUserMedia`
/// call. The app must declare `NSCameraUsageDescription` and
/// `NSMicrophoneUsageDescription` in `Info.plist`; iOS terminates an app that
/// triggers the system prompt without them.
public enum AgilCallPermissions {
    /// Keys the host app must provide in `Info.plist`.
    public static let requiredInfoPlistKeys = [
        "NSCameraUsageDescription",
        "NSMicrophoneUsageDescription"
    ]

    public static func current() -> AgilCallPermissionStatus {
        return AgilCallPermissionStatus(
            camera: status(for: .video),
            microphone: status(for: .audio)
        )
    }

    /// Requests undetermined permissions and returns the resulting status.
    /// Non-UI code; safe to call from an async task.
    @discardableResult
    public static func request(
        includeCamera: Bool = true,
        includeMicrophone: Bool = true
    ) async -> AgilCallPermissionStatus {
        if includeCamera && current().camera == .undetermined {
            _ = await requestAccess(for: .video)
        }
        if includeMicrophone && current().microphone == .undetermined {
            _ = await requestAccess(for: .audio)
        }
        return current()
    }

    private static func status(for mediaType: AVMediaType) -> AgilMediaPermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return .granted
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .undetermined
        @unknown default:
            return .unavailable
        }
    }

    private static func requestAccess(for mediaType: AVMediaType) async -> Bool {
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: mediaType) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

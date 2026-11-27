import SwiftUI
import UIKit
import AgilCallsSDK

/// Example host app for the AgilFrame iOS SDK.
///
/// Run the AgilFrame server locally (`npm run seed && npm start` from the repo
/// root), then open this app and press "Open call". The default server URL is
/// `http://localhost:8787` (loopback HTTP is allowed by the SDK for development;
/// `Info.plist` contains a localhost-only ATS exception).
///
/// The example deliberately does not embed an admin API key and never logs the
/// join token. In production, mint short-lived join tokens on your backend via
/// `POST /v1/rooms/:roomId/join` and pass only the token to the app.
struct ContentView: View {
    @State private var serverURL = "http://localhost:8787"
    @State private var tenantId = "demo"
    @State private var roomId = "demo"
    @State private var joinToken = ""
    @State private var participantName = "iOS SDK"
    @State private var theme: AgilThemeScheme = .dark
    @State private var configuration: AgilCallConfiguration?
    @State private var errorMessage: String?
    @State private var events: [String] = []
    @State private var showsLog = true
    @StateObject private var handle = CallHandle()

    var body: some View {
        Group {
            if let configuration = configuration {
                callScreen(configuration)
            } else {
                form
            }
        }
        .preferredColorScheme(.dark)
        .alert(isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Alert(
                title: Text("Configuration error"),
                message: Text(errorMessage ?? ""),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    // MARK: - Join screen

    private var form: some View {
        NavigationView {
            Form {
                Section(header: Text("Server"), footer: Text("HTTPS in production. Plain HTTP is accepted only for localhost / 127.0.0.1 / ::1.")) {
                    TextField("serverURL", text: $serverURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("tenantId", text: $tenantId)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }

                Section(header: Text("Room")) {
                    TextField("roomId", text: $roomId)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    SecureField("joinToken (optional)", text: $joinToken)
                    TextField("participantName", text: $participantName)
                }

                Section(header: Text("Appearance")) {
                    Picker("Theme", selection: $theme) {
                        ForEach(AgilThemeScheme.allCases, id: \.self) { scheme in
                            Text(scheme.rawValue).tag(scheme)
                        }
                    }
                }

                Section {
                    Button(action: openCall) {
                        Label("Open call", systemImage: "video.fill")
                    }
                }

                Section(header: Text("Events")) {
                    if events.isEmpty {
                        Text("No events yet").foregroundColor(.secondary)
                    } else {
                        ForEach(events.indices, id: \.self) { index in
                            Text(events[index])
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                }
            }
            .navigationTitle("AgilFrame iOS")
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Call screen

    private func callScreen(_ configuration: AgilCallConfiguration) -> some View {
        ZStack {
            AgilCall(
                configuration: configuration,
                respectsSafeArea: false,
                onViewReady: { view in
                    handle.view = view
                },
                onStateChange: { state in
                    handle.state = state
                },
                onFailure: { failure in
                    append("error \(failure.code.rawValue): \(failure.localizedDescription)")
                },
                onEvent: handleEvent
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(statusLine)
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.55))
                        .clipShape(Capsule())
                    Spacer()
                    toolButton("mic.fill", label: "Toggle microphone") { handle.toggleMicrophone() }
                    toolButton("video.fill", label: "Toggle camera") { handle.toggleCamera() }
                    toolButton("bubble.left.and.bubble.right.fill", label: "Toggle chat") { handle.toggleChat() }
                    toolButton("moon.fill", label: "Dark theme") { handle.view?.setTheme(.dark) }
                    toolButton("arrow.clockwise", label: "Reconnect") { handle.view?.reconnect() }
                    toolButton("doc.text.magnifyingglass", label: "Events") { showsLog.toggle() }
                    toolButton("xmark", label: "Close call") { closeCall() }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)

                Spacer()

                if showsLog {
                    eventLog
                        .frame(height: 120)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
            }
        }
    }

    private var eventLog: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(events.indices.suffix(20)), id: \.self) { index in
                    Text(events[index])
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.white.opacity(0.9))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func toolButton(
        _ systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(Color.black.opacity(0.55))
                .clipShape(Circle())
                .foregroundColor(.white)
        }
        .accessibilityLabel(label)
    }

    private var statusLine: String {
        return "room \(roomId) · \(handle.state.rawValue)"
    }

    // MARK: - Actions

    private func openCall() {
        do {
            let configuration = try AgilCallConfiguration(
                serverURL: serverURL,
                tenantId: tenantId,
                roomId: roomId,
                joinToken: joinToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : joinToken,
                participantName: participantName,
                theme: theme,
                maxParticipants: 200
            )
            self.configuration = configuration
            events.removeAll()
            append("opening room \(configuration.roomId)")
            // WKWebView asks for site permission itself; preflighting AVFoundation
            // makes the app-level prompt appear before the widget requests media.
            Task {
                let status = await AgilCallPermissions.request()
                if !status.cameraGranted || !status.microphoneGranted {
                    append("permissions camera=\(status.camera.rawValue) microphone=\(status.microphone.rawValue)")
                }
            }
        } catch let error as AgilConfigurationError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "Unexpected configuration error"
        }
    }

    private func closeCall() {
        handle.view?.leave()
        handle.view = nil
        configuration = nil
    }

    private func handleEvent(_ event: AgilCallEvent) {
        switch event {
        case .ready(let info):
            append("ready media=\(info.capabilities.media) blur=\(info.capabilities.blur) screenShare=\(info.capabilities.screenShare)")
        case .joined:
            append("joined")
        case .left:
            append("left")
        case .chat(let message):
            append("chat \(message.participantName ?? "guest"): \(message.text)")
        case .state(let state):
            append("state phase=\(state.phase ?? "-") peers=\(state.participants ?? 0)")
        case .participants(let update):
            append("participants \(update.kind.rawValue) count=\(update.count) +\(update.added.count)/-\(update.removed.count)")
        case .connection(let update):
            append("connection \(update.state.rawValue)\(update.attempt.map { " attempt=\($0)" } ?? "")")
        case .error(let failure):
            append("error \(failure.code.rawValue): \(failure.localizedDescription)")
        case .minimized(let minimized):
            append("minimized=\(minimized)")
        case .fullscreen(let fullscreen):
            append("fullscreen=\(fullscreen)")
        case .event(let name, _):
            append("event \(name)")
        }
    }

    private func append(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        events.append("\(formatter.string(from: Date()))  \(line)")
        if events.count > 100 {
            events.removeFirst(events.count - 100)
        }
    }
}

/// Holds a weak reference to the SDK view so SwiftUI buttons can send commands.
final class CallHandle: ObservableObject {
    weak var view: AgilCallView?
    @Published var state: AgilCallView.State = .idle

    func toggleMicrophone() {
        view?.toggleMicrophone()
    }

    func toggleCamera() {
        view?.toggleCamera()
    }

    func toggleChat() {
        view?.toggleChat()
    }
}

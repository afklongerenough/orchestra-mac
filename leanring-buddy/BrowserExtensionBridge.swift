//
//  BrowserExtensionBridge.swift
//  leanring-buddy
//
//  Orchestra's side of the Chrome extension: a WebSocket server on
//  127.0.0.1:43823 (this Mac only). The extension connects, proves itself
//  with a per-install token (written into its config.js by "Set up"), and
//  then runs the commands BrowserControl sends.
//
//  Checks: loopback only; the WebSocket Origin must be the Orchestra
//  extension's id when present; the first message must carry the token.
//

import AppKit
import Combine
import Foundation
import Network
import Security

@MainActor
final class BrowserExtensionBridge: ObservableObject {
    static let shared = BrowserExtensionBridge()

    @Published private(set) var isExtensionConnected = false
    @Published private(set) var statusText = "not set up"

    static let extensionFolderURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Orchestra", isDirectory: true)
        .appendingPathComponent("ChromeExtension", isDirectory: true)
    private static let tokenSecretName = "chrome-extension-token"

    private var listener: NWListener?
    private var authenticatedConnection: NWConnection?
    private var pendingRepliesByRequestIdentifier: [String: CheckedContinuation<String, Error>] = [:]

    struct BridgeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Setup

    /// Starts listening if the extension was set up before (cheap: one local port).
    func startIfSetUp() {
        guard KeychainStore.readCustomSecret(named: Self.tokenSecretName) != nil else { return }
        // Keep the extension's code in step with this build (Chrome picks it up
        // the next time the extension restarts; config.js and its token stay).
        do {
            try ChromeExtensionFiles.manifestJSON.write(to: Self.extensionFolderURL.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
            try ChromeExtensionFiles.backgroundJavaScript.write(to: Self.extensionFolderURL.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        } catch {
            OrchestraLog.write("🧩 Couldn't refresh the Chrome extension files: \(error.localizedDescription)")
        }
        startListening()
    }

    /// Writes the extension files (with a fresh token), starts the server and
    /// shows the folder plus Chrome's extensions page for "Load unpacked".
    func setUpExtension() {
        let pairingToken = KeychainStore.readCustomSecret(named: Self.tokenSecretName) ?? Self.makeRandomToken()
        KeychainStore.writeCustomSecret(pairingToken, named: Self.tokenSecretName)
        do {
            try FileManager.default.createDirectory(at: Self.extensionFolderURL, withIntermediateDirectories: true)
            try ChromeExtensionFiles.manifestJSON.write(to: Self.extensionFolderURL.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
            try ChromeExtensionFiles.backgroundJavaScript.write(to: Self.extensionFolderURL.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
            try ChromeExtensionFiles.configJavaScript(token: pairingToken).write(to: Self.extensionFolderURL.appendingPathComponent("config.js"), atomically: true, encoding: .utf8)
        } catch {
            statusText = "couldn't write the extension files: \(error.localizedDescription)"
            return
        }
        startListening()
        NSWorkspace.shared.activateFileViewerSelecting([Self.extensionFolderURL])
        // chrome:// pages can't be opened by link; ask Chrome directly.
        let openExtensionsPageProcess = Process()
        openExtensionsPageProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openExtensionsPageProcess.arguments = ["-a", "Google Chrome", "chrome://extensions"]
        try? openExtensionsPageProcess.run()
        statusText = "waiting for Chrome: turn on Developer mode, then Load unpacked → the ChromeExtension folder"
    }

    private static func makeRandomToken() -> String {
        var randomBytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        return randomBytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Server

    private func startListening() {
        guard listener == nil else { return }
        let webSocketOptions = NWProtocolWebSocket.Options()
        webSocketOptions.autoReplyPing = true
        let expectedOrigin = "chrome-extension://\(ChromeExtensionFiles.extensionIdentifier)"
        webSocketOptions.setClientRequestHandler(DispatchQueue.main) { _, additionalHeaders in
            // Only the Orchestra extension (or a client sending no Origin, which
            // still needs the token) may connect; web pages always send an Origin.
            let originHeaderValue = additionalHeaders.first { $0.name.lowercased() == "origin" }?.value
            let isAllowedOrigin = originHeaderValue == nil || originHeaderValue == expectedOrigin
            return NWProtocolWebSocket.Response(status: isAllowedOrigin ? .accept : .reject, subprotocol: nil, additionalHeaders: nil)
        }
        let listenerParameters = NWParameters.tcp
        listenerParameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)
        listenerParameters.requiredInterfaceType = .loopback
        guard let port = NWEndpoint.Port(rawValue: ChromeExtensionFiles.bridgePort),
              let newListener = try? NWListener(using: listenerParameters, on: port) else {
            statusText = "couldn't open the local port \(ChromeExtensionFiles.bridgePort)"
            return
        }
        newListener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in self?.accept(connection) }
        }
        // If the port is taken (a second copy of Orchestra, another app), say so
        // and let "Set up" try again instead of waiting forever.
        newListener.stateUpdateHandler = { [weak self] listenerState in
            guard case .failed(let listenerError) = listenerState else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.listener?.cancel()
                self.listener = nil
                if let authenticatedConnection = self.authenticatedConnection { self.handleClosed(authenticatedConnection) }
                self.statusText = "couldn't listen on port \(ChromeExtensionFiles.bridgePort) (\(listenerError.localizedDescription)); quit other copies of Orchestra and press Set up again"
                OrchestraLog.write("🧩 Chrome extension bridge: listener failed: \(listenerError.localizedDescription)")
            }
        }
        newListener.start(queue: .main)
        listener = newListener
        if !isExtensionConnected { statusText = "waiting for the Chrome extension" }
    }

    /// Per-connection flag (a class, so the callbacks share one copy).
    private final class ConnectionState {
        var hasAuthenticated = false
    }

    private func accept(_ connection: NWConnection) {
        let connectionState = ConnectionState()
        connection.stateUpdateHandler = { [weak self] connectionStatus in
            switch connectionStatus {
            case .failed, .cancelled:
                Task { @MainActor [weak self] in self?.handleClosed(connection) }
            default:
                break
            }
        }
        connection.start(queue: .main)
        // Unauthenticated connections get 5 seconds to say hello.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !connectionState.hasAuthenticated { connection.cancel() }
        }
        func receiveNextMessage() {
            connection.receiveMessage { [weak self] messageData, messageContext, _, receiveError in
                let webSocketMetadata = messageContext?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                let isCloseMessage = webSocketMetadata?.opcode == .close
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // An error, a close frame or no data at all means the socket is done:
                    // stop reading (asking again would spin).
                    guard receiveError == nil, !isCloseMessage, let messageData else {
                        self.handleClosed(connection)
                        return
                    }
                    guard let message = (try? JSONSerialization.jsonObject(with: messageData)) as? [String: Any] else {
                        receiveNextMessage()
                        return
                    }
                    if !connectionState.hasAuthenticated {
                        let expectedToken = KeychainStore.readCustomSecret(named: Self.tokenSecretName)
                        guard message["type"] as? String == "hello", let expectedToken,
                              message["token"] as? String == expectedToken else {
                            OrchestraLog.write("🧩 Chrome extension: refused a connection with a wrong token")
                            connection.cancel()
                            return
                        }
                        connectionState.hasAuthenticated = true
                        self.authenticatedConnection?.cancel()
                        self.authenticatedConnection = connection
                        self.isExtensionConnected = true
                        self.statusText = "connected"
                        OrchestraLog.write("🧩 Chrome extension connected")
                        // Rewriting background.js doesn't reload a running extension.
                        let extensionCodeVersion = (message["version"] as? Int) ?? 1
                        if extensionCodeVersion < ChromeExtensionFiles.extensionCodeVersion {
                            self.statusText = "connected (old version: press reload on Orchestra in chrome://extensions)"
                            OrchestraLog.write("🧩 Chrome extension is version \(extensionCodeVersion); reload it to get version \(ChromeExtensionFiles.extensionCodeVersion)")
                        }
                    } else if let requestIdentifier = message["id"] as? String,
                              let pendingReply = self.pendingRepliesByRequestIdentifier.removeValue(forKey: requestIdentifier) {
                        if message["ok"] as? Bool == true {
                            pendingReply.resume(returning: message["result"] as? String ?? "")
                        } else {
                            pendingReply.resume(throwing: BridgeError(message: message["error"] as? String ?? "the extension reported an error"))
                        }
                    }
                    receiveNextMessage()
                }
            }
        }
        receiveNextMessage()
    }

    private func handleClosed(_ connection: NWConnection) {
        connection.cancel()
        guard connection === authenticatedConnection else { return }
        authenticatedConnection = nil
        isExtensionConnected = false
        statusText = "waiting for the Chrome extension"
        for pendingReply in pendingRepliesByRequestIdentifier.values {
            pendingReply.resume(throwing: BridgeError(message: "the Chrome extension disconnected"))
        }
        pendingRepliesByRequestIdentifier.removeAll()
    }

    // MARK: - Commands

    /// Sends one command to the extension and waits for its answer (8 s, or 20 s
    /// for uploads). Kept short: Live mode waits on this while the user talks.
    func send(_ command: [String: Any]) async throws -> String {
        let commandAction = command["action"] as? String ?? ""
        // Clicks and uploads may already have happened when time runs out, so they
        // get longer and a reply that says "don't just retry".
        let isActionThatMayHaveHappened = commandAction == "click" || commandAction == "upload"
        let answerTimeoutNanoseconds: UInt64 = isActionThatMayHaveHappened ? 20_000_000_000 : 8_000_000_000
        let timeoutMessage = isActionThatMayHaveHappened
            ? "the \(commandAction) was sent but the page didn't answer in time; read the page again and check before doing it again"
            : "the Chrome extension didn't answer in time"
        guard let authenticatedConnection, isExtensionConnected else {
            throw BridgeError(message: "the Chrome extension isn't connected")
        }
        let requestIdentifier = UUID().uuidString
        var commandWithIdentifier = command
        commandWithIdentifier["id"] = requestIdentifier
        let commandData = try JSONSerialization.data(withJSONObject: commandWithIdentifier)
        return try await withCheckedThrowingContinuation { continuation in
            pendingRepliesByRequestIdentifier[requestIdentifier] = continuation
            let textMetadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let sendContext = NWConnection.ContentContext(identifier: "command", metadata: [textMetadata])
            authenticatedConnection.send(content: commandData, contentContext: sendContext, isComplete: true,
                                         completion: .contentProcessed { sendError in
                guard let sendError else { return }
                Task { @MainActor in
                    self.pendingRepliesByRequestIdentifier.removeValue(forKey: requestIdentifier)?
                        .resume(throwing: BridgeError(message: "couldn't reach the extension: \(sendError.localizedDescription)"))
                }
            })
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: answerTimeoutNanoseconds)
                self.pendingRepliesByRequestIdentifier.removeValue(forKey: requestIdentifier)?
                    .resume(throwing: BridgeError(message: timeoutMessage))
            }
        }
    }
}

//
//  GeminiLiveSession.swift
//  leanring-buddy
//
//  Optional "Live mode": a real-time, two-way voice conversation with
//  Gemini Live (you can talk naturally and interrupt it), like HeyClicky's
//  realtime voice. Tap the hotkey once to start, again to stop.
//
//  Protocol (raw WebSocket, v1beta BidiGenerateContent):
//    → {"setup": {...}}                       wait for setupComplete
//    → {"realtimeInput": {"audio": {...}}}    16 kHz 16-bit mono PCM, base64
//    → {"realtimeInput": {"video": {...}}}    JPEG screen frame, ≤ 1 per second
//    ← serverContent.modelTurn.parts[].inlineData   24 kHz 16-bit PCM to play
//    ← serverContent.interrupted              stop playback (barge-in)
//    ← toolCall.functionCalls                 → toolResponse.functionResponses
//
//  Echo: voice processing on the input node cancels the speaker so it
//  doesn't hear itself.
//

import AVFoundation
import Foundation

@MainActor
final class GeminiLiveSession: NSObject {
    enum LiveState: Equatable {
        case idle
        case connecting
        case live
        case failed(String)
    }

    /// Tools the live model can call. CompanionManager implements them.
    struct ToolHandlers {
        /// (x, y) on a 0–1000 grid over the latest screen frame → points the blue cursor.
        let pointAt: (_ normalizedX: Double, _ normalizedY: Double, _ label: String, _ screenCapture: CompanionScreenCapture) -> Void
        let runMacAction: (_ action: String) async -> String
        let startJob: (_ place: OrchestraJobPlace, _ brief: String, _ agentName: String?) -> String
        let createAgent: (_ name: String, _ purpose: String, _ place: OrchestraJobPlace) -> String
        let takeOverScreen: (_ goal: String) -> String
        let showMeHow: (_ goal: String) -> String
        let runBrowserAction: (_ action: String, _ elementIdentifier: Int?, _ text: String) async -> String
        let stopTakeover: () -> String
        let addRoutine: (_ schedule: String, _ place: OrchestraJobPlace, _ brief: String) -> String
        let recentJobsSummary: () -> String
        let endConversation: () -> String
        let rememberFact: (_ fact: String) -> String
        let forgetFact: (_ words: String) -> String
        let addReminder: (_ title: String, _ when: String) async -> String
        let addCalendarEvent: (_ title: String, _ start: String, _ end: String) async -> String
        let mySchedule: (_ day: String) async -> String
        let takeNotes: (_ action: String, _ topic: String) async -> String
    }

    static let defaultLiveModel = "gemini-3.8-live"

    private(set) var liveState: LiveState = .idle {
        didSet { onStateChange?(liveState) }
    }
    var onStateChange: ((LiveState) -> Void)?
    /// Rough mic level 0...1 for the waveform.
    var onMicrophoneLevel: ((CGFloat) -> Void)?
    /// Pieces of what was said, as Gemini transcribes them (for captions).
    var onTranscription: ((_ isUserSpeech: Bool, _ textChunk: String) -> Void)?
    /// The user talked over Orchestra (its reply was cut off).
    var onInterrupted: (() -> Void)?

    private let toolHandlers: ToolHandlers
    private let systemInstructionText: String

    private var webSocketTask: URLSessionWebSocketTask?
    private let urlSession = URLSession(configuration: .default)
    /// A fresh engine per session (reusing one after voice processing was
    /// toggled can leave it in a bad state).
    private var audioEngine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    /// Track what's actually set up, so cleanup never touches a half-built engine
    /// (removeTap/play on the wrong state raise exceptions Swift can't catch).
    private var isMicrophoneTapInstalled = false
    private var isPlayerNodeAttached = false
    /// Voice processing (echo cancellation) is what lowers other apps' volume;
    /// it must be switched off when Live ends or the music stays quiet.
    private var isVoiceProcessingOn = false
    private var audioConfigurationObserver: NSObjectProtocol?
    /// Guards against a restart loop: starting the engine can itself post a
    /// configuration change, so ignore changes while (and just after) rebuilding.
    private var isRestartingAudio = false
    /// Without echo cancellation the Mac's mic hears Orchestra's own voice from
    /// the speakers, Gemini thinks the user is talking and cuts itself off ("alr-", "its a-").
    /// So while it speaks (and a moment after), we send silence unless the user is
    /// clearly louder than the echo.
    private var isEchoCancellationActive = false
    private var modelSpeechPlaysUntil = Date.distantPast
    private static let speechEchoTailSeconds: TimeInterval = 0.4
    /// rmsLevel above this while Orchestra talks counts as the user talking over it.
    private static let bargeInMicrophoneLevel: CGFloat = 0.7
    /// The mic format the converter was built for; a change means rebuild.
    private var microphoneInputSampleRate: Double = 0
    /// Play the sound + flash once when the always-on frame stream starts
    /// (the "Live · screen" pill then shows it's still on).
    private var hasAnnouncedScreenStream = false
    /// What the user has said recently (from Live's input transcription), used to
    /// decide whether "only when asked" allows a look at the screen.
    private var recentUserSpeechText = ""
    /// What the user said in the last two minutes, chunk by chunk with times,
    /// so a connector "yes" can be checked against speech after the ask only.
    private var timedUserSpeechChunks: [(heardDate: Date, text: String)] = []
    private var lastUserSpeechDate = Date.distantPast
    private var sessionStartDate = Date()

    /// Seconds since anyone last spoke (user or Orchestra), for ending idle conversations.
    var secondsSinceLastConversationActivity: TimeInterval {
        let lastActivityDate = max(sessionStartDate, lastUserSpeechDate, modelSpeechPlaysUntil)
        return Date().timeIntervalSince(lastActivityDate)
    }
    private let microphoneTargetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private let playbackFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    private var screenFrameTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var isSetupComplete = false
    /// The most recent screen frame we sent, used to map pointing coordinates.
    private var latestScreenCapture: CompanionScreenCapture?

    init(systemInstructionText: String, toolHandlers: ToolHandlers) {
        self.systemInstructionText = systemInstructionText
        self.toolHandlers = toolHandlers
        super.init()
    }

    // MARK: - Start / stop

    func start() {
        guard liveState == .idle || liveStateIsFailed else { return }
        guard let apiKey = KeychainStore.read(.geminiAPIKey) else {
            liveState = .failed("no gemini api key yet")
            return
        }
        let liveModel = UserDefaults.standard.string(forKey: "geminiLiveModel") ?? Self.defaultLiveModel
        var urlComponents = URLComponents(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!
        urlComponents.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let webSocketURL = urlComponents.url else { return }

        liveState = .connecting
        sessionStartDate = Date()
        isSetupComplete = false
        let newWebSocketTask = urlSession.webSocketTask(with: webSocketURL)
        webSocketTask = newWebSocketTask
        newWebSocketTask.resume()
        receiveTask = Task { [weak self] in await self?.receiveLoop() }

        sendJSON(["setup": makeSetupMessage(liveModel: liveModel)])
    }

    func stop() {
        screenFrameTask?.cancel()
        screenFrameTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        stopAudio()
        isSetupComplete = false
        liveState = .idle
    }

    /// Ends the session after a problem: no frames, audio or socket keep running.
    private func failLive(_ reason: String) {
        screenFrameTask?.cancel()
        screenFrameTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        stopAudio()
        isSetupComplete = false
        liveState = .failed(reason)
    }

    private var liveStateIsFailed: Bool {
        if case .failed = liveState { return true }
        return false
    }

    // MARK: - Setup message

    private func makeSetupMessage(liveModel: String) -> [String: Any] {
        let voiceName = UserDefaults.standard.string(forKey: "geminiLiveVoice") ?? "Kore"
        let generationConfig: [String: Any] = [
            "responseModalities": ["AUDIO"],
            "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voiceName]]]
        ]
        let systemInstruction: [String: Any] = ["parts": [["text": systemInstructionText]]]
        // Audio + screen sessions are capped at ~2 minutes without compression.
        let contextWindowCompression: [String: Any] = ["slidingWindow": [String: Any]()]
        return [
            "model": "models/\(liveModel)",
            "generationConfig": generationConfig,
            "systemInstruction": systemInstruction,
            "tools": [["functionDeclarations": Self.liveFunctionDeclarations]],
            "contextWindowCompression": contextWindowCompression,
            // Less eager to decide someone started talking (fewer false interruptions).
            "realtimeInputConfig": [
                "automaticActivityDetection": ["startOfSpeechSensitivity": "START_SENSITIVITY_LOW"]
            ],
            "inputAudioTranscription": [String: Any](),
            "outputAudioTranscription": [String: Any]()
        ]
    }

    private static func stringParameters(_ parameterNames: [String], required requiredParameterNames: [String]) -> [String: Any] {
        var properties: [String: Any] = [:]
        for parameterName in parameterNames {
            properties[parameterName] = ["type": "string"]
        }
        return ["type": "object", "properties": properties, "required": requiredParameterNames]
    }

    private static let liveFunctionDeclarations: [[String: Any]] = [
        [
            "name": "point_at",
            "description": "Fly the blue cursor to a spot on the screen. x and y are on a 0-1000 grid over the latest screen frame: 0,0 = top-left corner, 1000,1000 = bottom-right, 500,500 = center (whatever the image size). Aim at the center of the thing.",
            "parameters": [
                "type": "object",
                "properties": [
                    "x": ["type": "number"] as [String: Any],
                    "y": ["type": "number"] as [String: Any],
                    "label": ["type": "string"] as [String: Any]
                ] as [String: Any],
                "required": ["x", "y"]
            ] as [String: Any]
        ],
        [
            "name": "mac_action",
            "description": "Do one quick thing on the Mac right now: 'spotify play <what>', 'spotify pause', 'spotify next', 'open_app <name>', 'open_url <link>', 'volume <0-100>', 'type <text>' (writes into the field that has focus), 'key <combo>' (e.g. 'key cmd+c' copies what's selected, 'key cmd+v' pastes, 'key cmd+a' selects all), 'scroll <lines>'. For 'spotify play <song>' use 'song by artist' when the user named one, otherwise just the song (their listening history picks the version). The result says what is actually playing: tell the user that, not what you asked for. Never for sending, posting, buying or deleting.",
            "parameters": stringParameters(["action"], required: ["action"])
        ],
        [
            "name": "start_job",
            "description": "Start a background job. place='hermes' for research, the user's accounts (email, calendar, files, notes, reminders), the web, github. place='mac' for work on this Mac's files and apps. agent = one of the user's named agents (from your instructions) when the request belongs to it; it then uses that agent's memory, and its usual place. The brief must stand on its own.",
            "parameters": stringParameters(["place", "brief", "agent"], required: ["brief"])
        ],
        [
            "name": "create_agent",
            "description": "Create a named agent the user wants to keep (e.g. 'make me a study agent for cmpt 201'). name = short name, purpose = what it's for in the user's words, place = 'hermes' or 'mac'.",
            "parameters": stringParameters(["name", "purpose", "place"], required: ["name", "purpose"])
        ],
        [
            "name": "take_over_screen",
            "description": "Drive the screen (click, select, type, keys) to finish a task that needs clicking or selecting. Runs in the background while you keep talking; you'll get a message when it finishes. The goal must stand on its own, since the screen agent can't hear you: say exactly what to do and quote the visible text/element (e.g. 'select the paragraph that starts with Dear team in the Mail window and copy it'). Stops before send/buy/delete and asks the user.",
            "parameters": stringParameters(["goal"], required: ["goal"])
        ],
        [
            "name": "show_me_how",
            "description": "Teach the user to do a task themselves: a guide points the blue cursor at each step, you'll get a note with each step to say, and it waits for them to do it. Goal must stand on its own (what they want to learn, in which app).",
            "parameters": stringParameters(["goal"], required: ["goal"])
        ],
        [
            "name": "browser",
            "description": "Work inside the web page in the front browser (Chrome, Brave, Edge, Arc, Safari). action: 'read' (title, address, buttons/links/fields with ids, page text) | 'click' (needs id) | 'type' (needs id and text; replaces the field's text) | 'open' (text = https address) | 'scroll' (text = screens, negative = up) | 'back'. With the Orchestra Chrome extension also: 'tabs' (lists open tabs with ids) | 'switch_tab' (id = tab id) | 'upload' (id = file picker id from read, text = full path of a file the user named, in Desktop/Documents/Downloads/Pictures/Movies/Music/~/Orchestra). Read first to get ids; ids change on every read. Never for send/buy/delete buttons.",
            "parameters": [
                "type": "object",
                "properties": [
                    "action": ["type": "string"] as [String: Any],
                    "id": ["type": "integer"] as [String: Any],
                    "text": ["type": "string"] as [String: Any]
                ] as [String: Any],
                "required": ["action"]
            ] as [String: Any]
        ],
        [
            "name": "connector_tool",
            "description": "Call a tool on one of the user's connected apps (custom connectors listed in your instructions). connector = its name, tool = the tool name, arguments_json = a JSON object string of arguments (\"{}\" if none). Risky tools are parked until the user says yes.",
            "parameters": stringParameters(["connector", "tool", "arguments_json"], required: ["connector", "tool"])
        ],
        [
            "name": "confirm_connector_action",
            "description": "Run the parked connector action, only right after the user clearly said yes to it. tool = the parked tool's name.",
            "parameters": stringParameters(["tool"], required: ["tool"])
        ],
        [
            "name": "stop_screen_takeover",
            "description": "Stop a running take_over_screen right away (when the user says stop / wait / cancel).",
            "parameters": stringParameters([], required: [])
        ],
        [
            "name": "add_routine",
            "description": "Make a repeating job. schedule: 'daily HH:MM', 'weekdays HH:MM', '<weekday> HH:MM', 'every N hours', 'every N minutes' (24-hour time).",
            "parameters": stringParameters(["schedule", "place", "brief"], required: ["schedule", "place", "brief"])
        ],
        [
            "name": "look_at_screen",
            "description": "Take one fresh look at the user's screen (use when the user asks you to look, or you need to see it). The image arrives right after this call.",
            "parameters": stringParameters([], required: [])
        ],
        [
            "name": "end_conversation",
            "description": "End this live conversation (close the mic) when the user says goodbye, that's all, thanks that's it, or stop listening. Say a short bye first.",
            "parameters": stringParameters([], required: [])
        ],
        [
            "name": "recent_jobs",
            "description": "List the user's recent jobs and their results.",
            "parameters": stringParameters([], required: [])
        ],
        [
            "name": "remember_fact",
            "description": "Keep one durable fact about the user across conversations (their courses, schedule, goals, how they like answers), or when they ask you to remember something. fact = one short line in third person, e.g. 'the user prefers short spoken answers and studies in the evening'. No secrets, passwords or tokens.",
            "parameters": stringParameters(["fact"], required: ["fact"])
        ],
        [
            "name": "forget_fact",
            "description": "Remove a remembered fact about the user, only when the user themselves asked to forget something this turn. words = the whole fact's wording; it removes only a fact that matches completely, and the reply says which fact was removed.",
            "parameters": stringParameters(["words"], required: ["words"])
        ],
        [
            "name": "add_reminder",
            "description": "Add a reminder straight to Apple Reminders on this Mac (no hermes). title = what to be reminded of, when = 'yyyy-MM-dd HH:mm' local time (empty for no due time). Use the current date from your instructions to resolve 'at 5', 'tomorrow', etc.",
            "parameters": stringParameters(["title", "when"], required: ["title"])
        ],
        [
            "name": "add_calendar_event",
            "description": "Add an event straight to Apple Calendar on this Mac (no hermes). title, start = 'yyyy-MM-dd HH:mm', end = 'yyyy-MM-dd HH:mm' (empty end = one hour). Local time; resolve relative times from the current date in your instructions.",
            "parameters": stringParameters(["title", "start", "end"], required: ["title", "start"])
        ],
        [
            "name": "my_schedule",
            "description": "Read this Mac's Apple Calendar events and due Apple Reminders for one day: day = 'today', 'tomorrow' or 'yyyy-MM-dd'. Prefer this over hermes for the mac's own calendar and reminders.",
            "parameters": stringParameters(["day"], required: [])
        ],
        [
            "name": "take_notes",
            "description": "Record a lecture or meeting and write summary notes afterwards. action = 'start' (only when the user themselves asked for notes this turn; topic = what it's about, optional) or 'stop' (finishes the recording, writes the notes and announces where they are). Notes are saved to ~/Orchestra/Notes or the folder the user picked.",
            "parameters": stringParameters(["action", "topic"], required: ["action"])
        ]
    ]

    // MARK: - Receiving

    private func receiveLoop() async {
        while !Task.isCancelled, let webSocketTask {
            let incomingMessage: URLSessionWebSocketTask.Message
            do {
                incomingMessage = try await webSocketTask.receive()
            } catch {
                if liveState != .idle {
                    OrchestraLog.write("🎙️ Live: connection closed: \(error)")
                    failLive("live connection closed: \(error.localizedDescription)")
                }
                return
            }
            let messageData: Data?
            switch incomingMessage {
            case .data(let data): messageData = data
            case .string(let text): messageData = text.data(using: .utf8)
            @unknown default: messageData = nil
            }
            guard let messageData,
                  let serverMessage = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any] else { continue }
            await handleServerMessage(serverMessage)
        }
    }

    private func handleServerMessage(_ serverMessage: [String: Any]) async {
        if serverMessage["setupComplete"] != nil {
            isSetupComplete = true
            guard await Self.ensureMicrophonePermission() else {
                OrchestraLog.write("🎙️ Live: microphone permission is not granted")
                failLive("the microphone permission is off for orchestra. turn it on in system settings, privacy and security, microphone")
                return
            }
            do {
                try startAudioWithFallback()
                liveState = .live
                startScreenFrames()
            } catch {
                OrchestraLog.write("🎙️ Live: microphone failed to start: \(error)")
                failLive("the microphone wouldn't start (\(error.localizedDescription))")
            }
            return
        }

        if let serverContent = serverMessage["serverContent"] as? [String: Any] {
            if let inputTranscription = serverContent["inputTranscription"] as? [String: Any],
               let spokenText = inputTranscription["text"] as? String {
                // A pause of 8 s+ starts a new utterance: an old "look at this"
                // doesn't carry over to a later question.
                if Date().timeIntervalSince(lastUserSpeechDate) > 8 {
                    recentUserSpeechText = ""
                }
                lastUserSpeechDate = Date()
                recentUserSpeechText = String((recentUserSpeechText + " " + spokenText).suffix(400))
                timedUserSpeechChunks.append((heardDate: Date(), text: spokenText))
                timedUserSpeechChunks.removeAll { Date().timeIntervalSince($0.heardDate) > 130 }
                onTranscription?(true, spokenText)
            }
            if let outputTranscription = serverContent["outputTranscription"] as? [String: Any],
               let spokenReplyText = outputTranscription["text"] as? String {
                onTranscription?(false, spokenReplyText)
            }
            if (serverContent["interrupted"] as? Bool) == true {
                // the user started talking: drop whatever we were saying.
                OrchestraLog.write("🎙️ Live: interrupted (heard speech while talking)")
                onInterrupted?()
                modelSpeechPlaysUntil = .distantPast
                if isPlayerNodeAttached && audioEngine.isRunning {
                    playerNode.stop()
                    playerNode.play()
                }
            }
            if let modelTurn = serverContent["modelTurn"] as? [String: Any],
               let parts = modelTurn["parts"] as? [[String: Any]] {
                for part in parts {
                    if let inlineData = part["inlineData"] as? [String: Any],
                       let base64Audio = inlineData["data"] as? String,
                       let audioData = Data(base64Encoded: base64Audio) {
                        schedulePlayback(ofPCM16Audio: audioData)
                    }
                }
            }
        }

        if let toolCall = serverMessage["toolCall"] as? [String: Any],
           let functionCalls = toolCall["functionCalls"] as? [[String: Any]] {
            var functionResponses: [[String: Any]] = []
            for functionCall in functionCalls {
                let callIdentifier = functionCall["id"] as? String ?? ""
                let functionName = functionCall["name"] as? String ?? ""
                let functionArguments = functionCall["args"] as? [String: Any] ?? [:]
                let resultText = await runTool(named: functionName, arguments: functionArguments)
                let functionResponse: [String: Any] = [
                    "id": callIdentifier,
                    "name": functionName,
                    "response": ["result": resultText]
                ]
                functionResponses.append(functionResponse)
            }
            sendJSON(["toolResponse": ["functionResponses": functionResponses]])
        }

        if let goAway = serverMessage["goAway"] as? [String: Any] {
            OrchestraLog.write("🎙️ Live: server going away soon \(goAway)")
        }
        if let serverError = serverMessage["error"] {
            OrchestraLog.write("🎙️ Live: server error \(serverError)")
        }
    }

    private func runTool(named functionName: String, arguments: [String: Any]) async -> String {
        switch functionName {
        case "point_at":
            guard let latestScreenCapture else { return "no screen frame yet" }
            let xValue = (arguments["x"] as? Double) ?? Double(arguments["x"] as? Int ?? 0)
            let yValue = (arguments["y"] as? Double) ?? Double(arguments["y"] as? Int ?? 0)
            toolHandlers.pointAt(xValue, yValue, arguments["label"] as? String ?? "here", latestScreenCapture)
            return "pointing"
        case "mac_action":
            return await toolHandlers.runMacAction(arguments["action"] as? String ?? "")
        case "start_job":
            let place: OrchestraJobPlace = (arguments["place"] as? String)?.lowercased() == "mac" ? .mac : .hermes
            let agentName = (arguments["agent"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return toolHandlers.startJob(place, arguments["brief"] as? String ?? "", agentName)
        case "create_agent":
            let place: OrchestraJobPlace = (arguments["place"] as? String)?.lowercased() == "mac" ? .mac : .hermes
            return toolHandlers.createAgent(arguments["name"] as? String ?? "", arguments["purpose"] as? String ?? "", place)
        case "take_over_screen":
            return toolHandlers.takeOverScreen(arguments["goal"] as? String ?? "")
        case "stop_screen_takeover":
            return toolHandlers.stopTakeover()
        case "connector_tool":
            let connectorIdentifier = (arguments["connector"] as? String ?? "").lowercased()
            let toolName = arguments["tool"] as? String ?? ""
            let argumentsJSONText = arguments["arguments_json"] as? String ?? "{}"
            if connectorIdentifier == GoogleConnectorManager.connectorIdentifier {
                return await GoogleConnectorManager.shared.runTool(toolName: toolName, argumentsJSONText: argumentsJSONText)
            }
            return await MCPConnectorManager.shared.runTool(
                connectorIdentifier: connectorIdentifier,
                toolName: toolName,
                argumentsJSONText: argumentsJSONText)
        case "confirm_connector_action":
            // Checked against what the user actually said, not the model's word.
            guard let parkedDate = MCPConnectorManager.shared.pendingRiskyCall?.createdDate else {
                return "nothing is waiting for a yes."
            }
            let userSpeechAfterParking = timedUserSpeechChunks
                .filter { $0.heardDate > parkedDate }
                .map { $0.text }
                .joined(separator: " ")
            return await MCPConnectorManager.shared.runPendingRiskyCall(
                userSpeechAfterParking: userSpeechAfterParking,
                expectedToolName: arguments["tool"] as? String)
        case "show_me_how":
            return toolHandlers.showMeHow(arguments["goal"] as? String ?? "")
        case "browser":
            // Reading a page shows its content to the model: same consent rule as looking at the screen.
            let browserAction = (arguments["action"] as? String ?? "read").lowercased()
            if browserAction == "read" && ScreenSharingMode.current == .onlyWhenAsked
                && (Date().timeIntervalSince(lastUserSpeechDate) > 45 || !ScreenPrivacySettings.transcriptAsksToLook(recentUserSpeechText)) {
                return "the user hasn't asked you to look, and their setting only allows looking when they ask. ask them if you may read the page."
            }
            let elementIdentifier = (arguments["id"] as? Int) ?? (arguments["id"] as? Double).map { Int($0) }
                ?? (arguments["id"] as? String).flatMap { Int($0) }
            return await toolHandlers.runBrowserAction(arguments["action"] as? String ?? "read",
                                                 elementIdentifier,
                                                 arguments["text"] as? String ?? "")
        case "add_routine":
            let place: OrchestraJobPlace = (arguments["place"] as? String)?.lowercased() == "mac" ? .mac : .hermes
            return toolHandlers.addRoutine(arguments["schedule"] as? String ?? "", place, arguments["brief"] as? String ?? "")
        case "look_at_screen":
            switch ScreenSharingMode.current {
            case .never:
                return "screen sharing is set to never in the orchestra menu, so you can't see the screen"
            case .onlyWhenAsked where Date().timeIntervalSince(lastUserSpeechDate) > 45
                                   || !ScreenPrivacySettings.transcriptAsksToLook(recentUserSpeechText):
                return "the user hasn't asked you to look, and their setting only allows looking when the user asks. ask them if you may look."
            default:
                break
            }
            guard await sendOneScreenFrame(announceCapture: true) else { return "couldn't capture the screen" }
            return "sent a fresh screenshot of the screen where the user's cursor is"
        case "end_conversation":
            return toolHandlers.endConversation()
        case "recent_jobs":
            return toolHandlers.recentJobsSummary()
        case "remember_fact":
            return toolHandlers.rememberFact(arguments["fact"] as? String ?? "")
        case "forget_fact":
            // Checked against what the user actually said this turn, not the
            // model's word: memories are only dropped on the user's request.
            guard OrchestraMemoryStore.userSpeechAsksToForget(recentUserSpeechText) else {
                return "the user hasn't asked to forget anything in their own words this turn. don't remove memories; ask them first."
            }
            return toolHandlers.forgetFact(arguments["words"] as? String ?? "")
        case "add_reminder":
            return await toolHandlers.addReminder(arguments["title"] as? String ?? "", arguments["when"] as? String ?? "")
        case "add_calendar_event":
            return await toolHandlers.addCalendarEvent(arguments["title"] as? String ?? "",
                                                       arguments["start"] as? String ?? "",
                                                       arguments["end"] as? String ?? "")
        case "my_schedule":
            return await toolHandlers.mySchedule(arguments["day"] as? String ?? "today")
        case "take_notes":
            let notesAction = (arguments["action"] as? String ?? "start").lowercased()
            // Recording the room needs the user's own spoken request this
            // turn — a model-initiated start is refused.
            if notesAction != "stop" && !OrchestraNoteTaker.userSpeechAsksToStartNotes(recentUserSpeechText) {
                return "the user hasn't asked for notes in their own words this turn. don't start recording; ask them if they want notes."
            }
            return await toolHandlers.takeNotes(notesAction, arguments["topic"] as? String ?? "")
        default:
            return "unknown tool"
        }
    }

    // MARK: - Sending

    /// Tells the live model something happened (e.g. a takeover finished) so it
    /// says it out loud. Uses clientContent, which starts a model turn.
    /// Waits for a quiet moment (up to `maximumWaitSeconds`) so it doesn't cut
    /// off the user or itself. Returns false if nothing was sent.
    @discardableResult
    func sendTextTurn(_ noteText: String, maximumWaitSeconds: Double = 10) async -> Bool {
        for _ in 0..<max(1, Int(maximumWaitSeconds * 4)) {
            let isModelSpeaking = Date() < modelSpeechPlaysUntil.addingTimeInterval(Self.speechEchoTailSeconds)
            let userSpokeRecently = Date().timeIntervalSince(lastUserSpeechDate) < 1.5
            if !isModelSpeaking && !userSpokeRecently { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return false }
        }
        guard liveState == .live, !Task.isCancelled else { return false }
        let userTurn: [String: Any] = ["role": "user", "parts": [["text": noteText]]]
        return sendJSON(["clientContent": ["turns": [userTurn], "turnComplete": true]])
    }

    /// False when there's no open connection (nothing was sent).
    @discardableResult
    private func sendJSON(_ message: [String: Any]) -> Bool {
        guard let webSocketTask,
              let messageData = try? JSONSerialization.data(withJSONObject: message),
              let messageText = String(data: messageData, encoding: .utf8) else { return false }
        webSocketTask.send(.string(messageText)) { error in
            if let error { print("⚠️ Live send failed: \(error.localizedDescription)") }
        }
        return true
    }

    // MARK: - Screen frames

    /// Sends the cursor screen about every 3 seconds (the API allows ≤ 1 fps).
    private func startScreenFrames() {
        screenFrameTask?.cancel()
        hasAnnouncedScreenStream = false
        screenFrameTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Re-read the setting every time, so switching to Never (or
                // "when asked") stops the stream mid-call.
                if ScreenSharingMode.current == .always {
                    let isFirstFrameOfStream = !self.hasAnnouncedScreenStream
                    // Announce once per stream, even if that send failed (no repeat cue every 3 s).
                    self.hasAnnouncedScreenStream = true
                    _ = await self.sendOneScreenFrame(announceCapture: isFirstFrameOfStream)
                } else {
                    // Switched away from Always: announce again if it's switched back on.
                    self.hasAnnouncedScreenStream = false
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    /// Captures the cursor screen once and sends it as a video frame.
    private func sendOneScreenFrame(announceCapture: Bool) async -> Bool {
        guard ScreenSharingMode.current != .never else { return false }
        guard let screenCaptures = try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG(announceCapture: announceCapture),
              let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first else {
            return false
        }
        let videoFrame: [String: Any] = [
            "data": cursorScreenCapture.imageData.base64EncodedString(),
            "mimeType": "image/jpeg"
        ]
        guard sendJSON(["realtimeInput": ["video": videoFrame]]) else { return false }
        // Map pointing to the frame we handed to the socket.
        latestScreenCapture = cursorScreenCapture
        return true
    }

    // MARK: - Audio

    /// Asks for the microphone if needed; false if the user said no.
    private static func ensureMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { isGranted in continuation.resume(returning: isGranted) }
            }
        default:
            return false
        }
    }

    /// Echo cancellation (voice processing) first; some Macs/headsets can't
    /// start with it, so retry once without it (headphones recommended then).
    private func startAudioWithFallback() throws {
        // Bluetooth headphones (AirPods…): listen with the Mac's built-in mic so
        // the headphones stay in high-quality mode and music keeps playing. The
        // sound is in the user's ears, so there's no echo to cancel or mute for.
        if PreferredMicrophone.builtInMicrophoneReplacingBluetooth() != nil {
            do {
                try startAudio(useVoiceProcessing: false, useBuiltInMicrophone: true)
                isEchoCancellationActive = true
                OrchestraLog.write("🎙️ Live: microphone started (built-in mic, Bluetooth headphones for sound)")
                return
            } catch {
                OrchestraLog.write("🎙️ Live: built-in mic failed (\(error)); trying the headphones' mic")
                stopAudio()
            }
        }
        // A Bluetooth headset's own mic: macOS's echo cancellation can hand back
        // pure silence from it, and with headphones there's no echo anyway.
        if PreferredMicrophone.defaultInputIsBluetooth {
            try startAudio(useVoiceProcessing: false)
            isEchoCancellationActive = true
            OrchestraLog.write("🎙️ Live: microphone started (Bluetooth headset mic, no echo cancellation needed)")
            return
        }
        do {
            try startAudio(useVoiceProcessing: true)
            isEchoCancellationActive = true
            OrchestraLog.write("🎙️ Live: microphone started with echo cancellation")
        } catch {
            isEchoCancellationActive = false
            OrchestraLog.write("🎙️ Live: echo-cancelled mic failed (\(error)); retrying without it")
            stopAudio()
            try startAudio(useVoiceProcessing: false)
            OrchestraLog.write("🎙️ Live: microphone started without echo cancellation (Orchestra's voice mutes the mic while it talks)")
        }
    }

    private func startAudio(useVoiceProcessing: Bool, useBuiltInMicrophone: Bool = false) throws {
        // Never leave an earlier engine running with a hot mic.
        stopAudio()
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        // Create the output side before turning on voice processing; macOS
        // initializes the echo canceller on the output node.
        _ = audioEngine.mainMixerNode
        _ = audioEngine.outputNode
        if useBuiltInMicrophone {
            guard PreferredMicrophone.applyPreferredMicrophone(to: audioEngine, logLabel: "Live") else {
                throw NSError(domain: "GeminiLive", code: 3, userInfo: [NSLocalizedDescriptionKey: "couldn't switch to the built-in mic"])
            }
        }
        let inputNode = audioEngine.inputNode
        if useVoiceProcessing {
            try inputNode.setVoiceProcessingEnabled(true)
            isVoiceProcessingOn = true
            // Echo cancellation turns other apps' sound down. Keep that gentle and
            // only while someone is actually talking, so music stays loud.
            inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: true, duckingLevel: .min)
        }

        audioEngine.attach(playerNode)
        isPlayerNodeAttached = true
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: playbackFormat)

        let inputFormat = inputNode.outputFormat(forBus: 0)
        // A 0 Hz / 0-channel format means no usable input device; installTap would crash on it.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "GeminiLive", code: 2, userInfo: [NSLocalizedDescriptionKey: "no microphone input found"])
        }
        microphoneInputSampleRate = inputFormat.sampleRate
        OrchestraLog.write("🎙️ Live: mic format \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch, voice processing \(useVoiceProcessing)")
        guard let microphonePCMConverter = MicrophonePCMConverter(inputFormat: inputFormat, outputFormat: microphoneTargetFormat) else {
            throw NSError(domain: "GeminiLive", code: 1, userInfo: [NSLocalizedDescriptionKey: "can't convert the microphone audio"])
        }

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] inputBuffer, _ in
            // Runs on an audio thread: convert here (the converter isn't tied
            // to the main actor), then hop to the main actor to send.
            let convertedAudioData = microphonePCMConverter.convert(inputBuffer)
            let microphoneLevel = MicrophonePCMConverter.rmsLevel(of: inputBuffer)
            Task { @MainActor in
                guard let self else { return }
                self.onMicrophoneLevel?(microphoneLevel)
                guard self.isSetupComplete, let convertedAudioData, !convertedAudioData.isEmpty else { return }
                var audioToSend = convertedAudioData
                let isModelSpeaking = Date() < self.modelSpeechPlaysUntil.addingTimeInterval(Self.speechEchoTailSeconds)
                if !self.isEchoCancellationActive && isModelSpeaking && microphoneLevel < Self.bargeInMicrophoneLevel {
                    // Same length of silence keeps the stream steady.
                    audioToSend = Data(count: convertedAudioData.count)
                }
                let audioChunk: [String: Any] = [
                    "data": audioToSend.base64EncodedString(),
                    "mimeType": "audio/pcm;rate=16000"
                ]
                self.sendJSON(["realtimeInput": ["audio": audioChunk]])
            }
        }

        isMicrophoneTapInstalled = true

        audioEngine.prepare()
        try audioEngine.start()
        playerNode.play()

        // Headphones plugged in / device switched: rebuild the audio graph.
        audioConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.restartAudioAfterDeviceChange()
            }
        }
    }

    /// Rebuilds the mic after a device change. The new device's format often
    /// isn't ready right away (0 Hz), so wait a moment and retry a few times.
    private func restartAudioAfterDeviceChange() async {
        guard liveState == .live, !isRestartingAudio else { return }
        isRestartingAudio = true
        defer { isRestartingAudio = false }
        // Let the new device settle. A real device change stops the engine;
        // if it's still running, this was just an echo of our own start.
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard liveState == .live else { return }
        // Still running on the same format: just an echo of our own start.
        // (A device can also change rate while the engine keeps running.)
        // Only read the input format while the engine is known to be healthy.
        if audioEngine.isRunning && isMicrophoneTapInstalled
            && audioEngine.inputNode.outputFormat(forBus: 0).sampleRate == microphoneInputSampleRate { return }
        OrchestraLog.write("🎙️ Live: audio device changed, restarting the microphone")
        stopAudio()
        for attemptNumber in 1...3 {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard liveState == .live else { return }
            do {
                try startAudioWithFallback()
                return
            } catch {
                OrchestraLog.write("🎙️ Live: mic restart attempt \(attemptNumber) failed: \(error)")
            }
        }
        failLive("the microphone stopped after the audio device changed")
    }

    private func stopAudio() {
        if let audioConfigurationObserver {
            NotificationCenter.default.removeObserver(audioConfigurationObserver)
            self.audioConfigurationObserver = nil
        }
        if isMicrophoneTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isMicrophoneTapInstalled = false
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if isPlayerNodeAttached {
            playerNode.stop()
            audioEngine.detach(playerNode)
            isPlayerNodeAttached = false
        }
        if isVoiceProcessingOn {
            try? audioEngine.inputNode.setVoiceProcessingEnabled(false)
            isVoiceProcessingOn = false
        }
        // Drop the old engine entirely so nothing keeps the audio system in
        // "call mode" (which keeps other sound turned down) after Live ends.
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
    }

    /// 24 kHz 16-bit PCM from Gemini → Float32 buffer → player.
    private func schedulePlayback(ofPCM16Audio audioData: Data) {
        let sampleCount = audioData.count / MemoryLayout<Int16>.size
        guard sampleCount > 0,
              let playbackBuffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(sampleCount)),
              let floatChannel = playbackBuffer.floatChannelData else { return }
        playbackBuffer.frameLength = AVAudioFrameCount(sampleCount)
        audioData.withUnsafeBytes { rawBuffer in
            let int16Samples = rawBuffer.bindMemory(to: Int16.self)
            for sampleIndex in 0..<sampleCount {
                floatChannel[0][sampleIndex] = Float(Int16(littleEndian: int16Samples[sampleIndex])) / 32768.0
            }
        }
        guard isPlayerNodeAttached, audioEngine.isRunning else { return }
        playerNode.scheduleBuffer(playbackBuffer, completionHandler: nil)
        // Queue-aware: this chunk plays after whatever is already queued.
        let chunkDurationSeconds = Double(sampleCount) / playbackFormat.sampleRate
        modelSpeechPlaysUntil = max(modelSpeechPlaysUntil, Date()).addingTimeInterval(chunkDurationSeconds)
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }
}

/// Converts mic buffers to 16 kHz mono 16-bit PCM. Lives off the main actor
/// because the audio tap calls it on a real-time audio thread.
final class MicrophonePCMConverter: @unchecked Sendable {
    private let audioConverter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    /// Mono Float32 at the mic's rate. Voice-processed input is often several
    /// channels, which AVAudioConverter can't downmix to mono by itself, so we
    /// copy the first channel into this format first.
    private let monoInputFormat: AVAudioFormat

    init?(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) {
        guard let monoInputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate,
                                                  channels: 1, interleaved: false),
              let audioConverter = AVAudioConverter(from: monoInputFormat, to: outputFormat) else { return nil }
        self.audioConverter = audioConverter
        self.outputFormat = outputFormat
        self.monoInputFormat = monoInputFormat
    }

    func convert(_ originalInputBuffer: AVAudioPCMBuffer) -> Data? {
        guard let inputBuffer = monoCopy(of: originalInputBuffer) else { return nil }
        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 16
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else { return nil }

        var hasProvidedInput = false
        var conversionError: NSError?
        audioConverter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if hasProvidedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            hasProvidedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        guard conversionError == nil, let int16Channel = outputBuffer.int16ChannelData else { return nil }
        return Data(bytes: int16Channel[0], count: Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size)
    }

    /// First channel of any Float32 or Int16 buffer, as mono Float32.
    private func monoCopy(of sourceBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frameCount = sourceBuffer.frameLength
        // If the device changed rate mid-session, drop the buffer rather than
        // send wrong-speed audio (the engine is rebuilt on configuration change).
        guard sourceBuffer.format.sampleRate == monoInputFormat.sampleRate, frameCount > 0,
              let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoInputFormat, frameCapacity: frameCount),
              let monoChannel = monoBuffer.floatChannelData?[0] else { return nil }
        monoBuffer.frameLength = frameCount
        let isInterleaved = sourceBuffer.format.isInterleaved
        let channelCount = Int(sourceBuffer.format.channelCount)
        if let floatChannels = sourceBuffer.floatChannelData {
            for frameIndex in 0..<Int(frameCount) {
                monoChannel[frameIndex] = isInterleaved ? floatChannels[0][frameIndex * channelCount] : floatChannels[0][frameIndex]
            }
        } else if let int16Channels = sourceBuffer.int16ChannelData {
            for frameIndex in 0..<Int(frameCount) {
                let sample = isInterleaved ? int16Channels[0][frameIndex * channelCount] : int16Channels[0][frameIndex]
                monoChannel[frameIndex] = Float(sample) / 32768.0
            }
        } else {
            return nil
        }
        return monoBuffer
    }

    static func rmsLevel(of buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let floatChannel = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var sumOfSquares: Float = 0
        for sampleIndex in 0..<Int(buffer.frameLength) {
            let sample = floatChannel[0][sampleIndex]
            sumOfSquares += sample * sample
        }
        let rms = sqrt(sumOfSquares / Float(buffer.frameLength))
        return CGFloat(min(1, rms * 8))
    }
}

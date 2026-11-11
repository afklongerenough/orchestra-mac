//
//  MacAgentJobRunner.swift
//  leanring-buddy
//
//  The on-Mac background agent for [MACJOB: ...] jobs — Orchestra's own
//  version of HeyClicky's local agent harness. It's a Gemini function-calling
//  loop that works inside the job's folder (~/Orchestra/Jobs/<job>/) with:
//
//    run_shell      zsh command in the job folder (60 s timeout)
//    read_file / write_file / list_folder / find_files (Spotlight)
//    open           open a file or link for the user
//    mac_action     the same [ACTION:] commands the voice side uses
//    update_note    rewrite note.md — the live page the user watches
//    finish         final answer (becomes report.md)
//
//  Safety: every shell command runs under a macOS sandbox profile that only
//  allows writes inside the job folder (plus temp/caches) and blocks reading
//  credentials; moving the user's files goes through move_file (never overwrites);
//  nothing can delete their files. Sending/posting/buying is left to the user.
//

import AppKit
import Foundation

@MainActor
final class MacAgentJobRunner {
    struct Outcome {
        let succeeded: Bool
        let finalAnswer: String
    }

    private let jobFolderURL: URL
    private let brief: String
    private let spokenRequest: String
    private let geminiAPI: GeminiAPI
    private let macActionRunner: MacActionRunner
    private let maximumStepCount = 40
    private let maximumWallSeconds: TimeInterval = 20 * 60

    private var contents: [[String: Any]] = []
    private var agentLogLines: [String] = []

    init(jobFolderURL: URL, brief: String, spokenRequest: String, geminiAPI: GeminiAPI, macActionRunner: MacActionRunner) {
        self.jobFolderURL = jobFolderURL
        self.brief = brief
        self.spokenRequest = spokenRequest
        self.geminiAPI = geminiAPI
        self.macActionRunner = macActionRunner
    }

    var noteFileURL: URL { jobFolderURL.appendingPathComponent("note.md") }

    func run() async -> Outcome {
        let startedAt = Date()
        try? FileManager.default.createDirectory(at: jobFolderURL.appendingPathComponent("output"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: jobFolderURL.appendingPathComponent("tmp"), withIntermediateDirectories: true)

        contents = [[
            "role": "user",
            "parts": [["text": """
            job brief: \(brief)
            the user's exact words: "\(spokenRequest)"
            job folder (your working directory): \(jobFolderURL.path)
            today: \(Self.todayText())
            """]]
        ]]

        for stepNumber in 1...maximumStepCount {
            if Task.isCancelled {
                return Outcome(succeeded: false, finalAnswer: "stopped before finishing.")
            }
            if Date().timeIntervalSince(startedAt) > maximumWallSeconds {
                return Outcome(succeeded: false, finalAnswer: "ran out of time (20 minutes). what's done so far is in the job folder.")
            }

            var requestBody: [String: Any] = [
                "systemInstruction": ["parts": [["text": Self.agentSystemPrompt]]],
                "contents": contents,
                "tools": [["functionDeclarations": Self.functionDeclarations]]
            ]
            if stepNumber > maximumStepCount - 3 {
                requestBody["systemInstruction"] = ["parts": [["text": Self.agentSystemPrompt + "\n\nyou are almost out of steps. wrap up now: call finish with what you have."]]]
            }

            let responseJSON: [String: Any]
            do {
                responseJSON = try await geminiAPI.generateContentRaw(body: requestBody)
            } catch {
                return Outcome(succeeded: false, finalAnswer: "the model stopped answering: \(error.localizedDescription)")
            }

            guard let candidates = responseJSON["candidates"] as? [[String: Any]],
                  let modelContent = candidates.first?["content"] as? [String: Any],
                  let modelParts = modelContent["parts"] as? [[String: Any]] else {
                return Outcome(succeeded: false, finalAnswer: "gemini returned nothing usable.")
            }

            // Keep the model's turn exactly as returned (it can carry thought
            // signatures that newer Gemini models require on the next call).
            contents.append(["role": "model", "parts": modelParts])

            let functionCalls = modelParts.compactMap { $0["functionCall"] as? [String: Any] }
            if functionCalls.isEmpty {
                // Plain text with no tool call = the model thinks it's done.
                let plainText = modelParts.filter { ($0["thought"] as? Bool) != true }
                    .compactMap { $0["text"] as? String }.joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return Outcome(succeeded: true, finalAnswer: plainText.isEmpty ? "done." : plainText)
            }

            var functionResponseParts: [[String: Any]] = []
            for functionCall in functionCalls {
                let functionName = functionCall["name"] as? String ?? ""
                let functionArguments = functionCall["args"] as? [String: Any] ?? [:]

                if functionName == "finish" {
                    let finalAnswer = functionArguments["answer"] as? String ?? "done."
                    writeAgentLog()
                    return Outcome(succeeded: true, finalAnswer: finalAnswer)
                }

                let toolResultText = await runTool(named: functionName, arguments: functionArguments)
                agentLogLines.append("[\(stepNumber)] \(functionName) \(Self.compactJSON(functionArguments).prefix(300)) -> \(toolResultText.prefix(300))")
                let functionResponse: [String: Any] = [
                    "name": functionName,
                    "response": ["result": toolResultText]
                ]
                functionResponseParts.append(["functionResponse": functionResponse])
            }
            contents.append(["role": "user", "parts": functionResponseParts])
            writeAgentLog()
        }
        return Outcome(succeeded: false, finalAnswer: "used all \(maximumStepCount) steps without finishing. what's done so far is in the job folder.")
    }

    // MARK: - Tools

    private func runTool(named functionName: String, arguments: [String: Any]) async -> String {
        switch functionName {
        case "run_shell":
            return await runShellCommand(arguments["command"] as? String ?? "")
        case "read_file":
            return readFile(arguments["path"] as? String ?? "")
        case "write_file":
            return writeFile(arguments["path"] as? String ?? "", contents: arguments["content"] as? String ?? "")
        case "list_folder":
            return listFolder(arguments["path"] as? String ?? ".")
        case "find_files":
            return await runShellCommand("mdfind -name \(Self.shellQuoted(arguments["name"] as? String ?? "")) | head -30")
        case "open":
            let target = arguments["target"] as? String ?? ""
            if target.hasPrefix("http://") || target.hasPrefix("https://"), let url = URL(string: target) {
                return NSWorkspace.shared.open(url) ? "opened \(target)" : "couldn't open \(target)"
            }
            let fileURL = resolvePath(target)
            return NSWorkspace.shared.open(fileURL) ? "opened \(fileURL.path)" : "couldn't open \(fileURL.path)"
        case "mac_action":
            let results = await macActionRunner.runActions([arguments["action"] as? String ?? ""])
            guard let result = results.first else { return "no result" }
            return result.succeeded ? "ok" : "failed: \(result.detail ?? "error")"
        case "move_file":
            return moveFile(from: arguments["from"] as? String ?? "", to: arguments["to"] as? String ?? "")
        case "update_note":
            let noteMarkdown = arguments["markdown"] as? String ?? ""
            do {
                try noteMarkdown.write(to: noteFileURL, atomically: true, encoding: .utf8)
                return "note saved (\(noteMarkdown.count) characters)"
            } catch {
                return "couldn't save note: \(error.localizedDescription)"
            }
        default:
            return "unknown tool \(functionName)"
        }
    }

    private func resolvePath(_ pathText: String) -> URL {
        var expandedPath = pathText.trimmingCharacters(in: .whitespacesAndNewlines)
        if expandedPath == "~" || expandedPath.hasPrefix("~/") {
            expandedPath = FileManager.default.homeDirectoryForCurrentUser.path + expandedPath.dropFirst()
        }
        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath)
        }
        return jobFolderURL.appendingPathComponent(expandedPath.isEmpty ? "." : expandedPath)
    }

    /// Home-relative places the agent may never read or write (credentials,
    /// browser data, mail and messages, other agents' config).
    private static let privateHomeRelativePaths = [
        ".ssh", ".gnupg", ".aws", ".netrc", ".docker", ".kube", ".config/gh", ".config/gcloud", ".config/hermes",
        "Library/Keychains", "Library/Cookies", "Library/Mail", "Library/Messages", "Library/Safari",
        "Library/Application Support/Google/Chrome", "Library/Application Support/BraveSoftware",
        "Library/Application Support/Firefox", "Library/Application Support/Arc",
        "Library/Application Support/Claude", "Library/Application Support/com.apple.TCC"
    ]

    /// Home-relative folders the agent may write into or move files within
    /// (besides its own job folder). Everything else in ~ — ~/Library
    /// (LaunchAgents!), dotfiles — is off limits for writes.
    private static let writableHomeRelativeFolders = ["Desktop", "Documents", "Downloads", "Orchestra", "Pictures", "Movies", "Music"]

    /// Resolves ~, symlinks and ".." and lowercases, so "~/.SSH" can't sneak past
    /// on a case-insensitive disk.
    private func normalizedLowercasePath(_ fileURL: URL) -> String {
        fileURL.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
    }

    private func isPrivatePath(_ fileURL: URL) -> Bool {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path.lowercased()
        let candidatePath = normalizedLowercasePath(fileURL)
        if candidatePath.hasSuffix("/.env") || candidatePath.contains("/.env.") { return true }
        return Self.privateHomeRelativePaths.contains { privateRelativePath in
            let privatePath = homePath + "/" + privateRelativePath.lowercased()
            return candidatePath == privatePath || candidatePath.hasPrefix(privatePath + "/")
        }
    }

    private func isWritableLocation(_ fileURL: URL) -> Bool {
        let candidatePath = normalizedLowercasePath(fileURL)
        if candidatePath.hasPrefix(normalizedLowercasePath(jobFolderURL) + "/") { return true }
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path.lowercased()
        return Self.writableHomeRelativeFolders.contains { folderName in
            candidatePath.hasPrefix(homePath + "/" + folderName.lowercased() + "/")
        }
    }

    private func readFile(_ pathText: String) -> String {
        let fileURL = resolvePath(pathText)
        if isPrivatePath(fileURL) { return "that file is private to this mac." }
        guard let data = try? Data(contentsOf: fileURL) else { return "couldn't read \(fileURL.path)" }
        guard let text = String(data: data, encoding: .utf8) else {
            return "\(fileURL.path) is a binary file (\(data.count) bytes); use run_shell with a converter (e.g. textutil, pdftotext if installed, sips)."
        }
        return text.count > 30_000 ? String(text.prefix(30_000)) + "\n…(truncated, \(text.count) characters total)" : text
    }

    private func writeFile(_ pathText: String, contents fileContents: String) -> String {
        let fileURL = resolvePath(pathText)
        if isPrivatePath(fileURL) { return "that location is private to this mac." }
        if !isWritableLocation(fileURL) {
            return "i can only save files in the job folder, Desktop, Documents, Downloads, Pictures, Movies, Music or ~/Orchestra."
        }
        // Outside the job folder, never overwrite an existing file.
        let isInsideJobFolder = fileURL.path.hasPrefix(jobFolderURL.path)
        if !isInsideJobFolder && FileManager.default.fileExists(atPath: fileURL.path) {
            return "\(fileURL.path) already exists and is outside the job folder; pick a new name or ask the user."
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileContents.write(to: fileURL, atomically: true, encoding: .utf8)
            return "wrote \(fileURL.path)"
        } catch {
            return "couldn't write \(fileURL.path): \(error.localizedDescription)"
        }
    }

    private func listFolder(_ pathText: String) -> String {
        let folderURL = resolvePath(pathText)
        if isPrivatePath(folderURL) { return "that folder is private to this mac." }
        guard let itemNames = try? FileManager.default.contentsOfDirectory(atPath: folderURL.path) else {
            return "couldn't list \(folderURL.path)"
        }
        let visibleItemNames = itemNames.filter { !$0.hasPrefix(".") }.sorted().prefix(200)
        return "\(folderURL.path)\n" + (visibleItemNames.isEmpty ? "(empty)" : visibleItemNames.joined(separator: "\n"))
    }

    /// Quick refusals for obviously dangerous commands. The real protection
    /// is the macOS sandbox profile below, which the shell can't get around.
    private static let blockedCommandFragments = ["sudo", "mkfs", "diskutil erase", ":(){", "shutdown", "reboot", "launchctl", "csrutil", "security find-", "security dump"]

    /// sandbox-exec profile for every agent command:
    /// - writes only inside the job folder, temp folders and tool caches
    ///   (no deleting or changing the user's files from the shell — moves go
    ///   through the move_file tool, which never overwrites)
    /// - no reading credentials (ssh keys, keychains, cloud configs, .env files)
    private func makeSandboxProfile() -> String {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let jobFolderPath = jobFolderURL.path
        func quoted(_ path: String) -> String { "\"" + path.replacingOccurrences(of: "\"", with: "") + "\"" }
        let privateReadDenyRules = Self.privateHomeRelativePaths
            .map { "(subpath \(quoted(homePath + "/" + $0)))" }
            .joined(separator: " ")
        return """
        (version 1)
        (allow default)
        (deny file-write* (subpath \(quoted(homePath))) (subpath "/Applications") (subpath "/Library") (subpath "/usr/local") (subpath "/opt") (subpath "/Volumes"))
        (allow file-write* (subpath \(quoted(jobFolderPath))) (subpath "/private/tmp") (subpath "/private/var/tmp") (subpath "/private/var/folders")
            (literal "/dev/null") (literal "/dev/tty") (literal "/dev/stdout") (literal "/dev/stderr") (subpath "/dev/fd")
            (subpath \(quoted(homePath + "/Library/Caches"))) (subpath \(quoted(homePath + "/.cache"))))
        (deny file-read* \(privateReadDenyRules) (regex #"/\\.env(\\..*)?$"#))
        (deny process-exec (literal "/usr/bin/osascript") (literal "/usr/bin/open") (literal "/usr/bin/shortcuts")
            (literal "/usr/bin/automator") (literal "/usr/bin/security") (literal "/usr/bin/sudo") (literal "/bin/launchctl"))
        """
    }

    private func runShellCommand(_ commandText: String) async -> String {
        let lowercasedCommand = commandText.lowercased()
        if let blockedFragment = Self.blockedCommandFragments.first(where: { lowercasedCommand.contains($0) }) {
            return "blocked: commands containing \"\(blockedFragment)\" aren't allowed. ask the user to do it themselves."
        }

        let shellProcess = Process()
        shellProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        shellProcess.arguments = ["-p", makeSandboxProfile(), "/bin/zsh", "-lc", commandText]
        shellProcess.currentDirectoryURL = jobFolderURL
        let outputPipe = Pipe()
        shellProcess.standardOutput = outputPipe
        shellProcess.standardError = outputPipe

        // Drain the pipe while the command runs so big outputs can't fill the
        // 64 KB pipe buffer and freeze the command.
        let outputCollector = ShellOutputCollector()
        outputPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            outputCollector.append(fileHandle.availableData)
        }

        do {
            try shellProcess.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            return "couldn't start the shell: \(error.localizedDescription)"
        }

        // Wait up to 60 s, staying responsive to job cancellation.
        let deadline = Date().addingTimeInterval(60)
        while shellProcess.isRunning && Date() < deadline && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        var stopReason: String?
        if shellProcess.isRunning {
            stopReason = Task.isCancelled ? "stopped (job cancelled)" : "timed out after 60 s"
            let rootProcessIdentifier = shellProcess.processIdentifier
            // pgrep + kill off the main actor.
            await Task.detached { Self.terminateProcessTree(rootProcessIdentifier: rootProcessIdentifier) }.value
        }
        // Keep reading briefly so output still buffered in the pipe isn't lost.
        try? await Task.sleep(nanoseconds: 250_000_000)
        outputPipe.fileHandleForReading.readabilityHandler = nil

        var outputText = outputCollector.text
        if outputText.count > 12_000 {
            outputText = "…(first part cut)\n" + String(outputText.suffix(12_000))
        }
        if outputText.contains("Operation not permitted") || outputText.contains("deny") && outputText.contains("sandbox") {
            outputText += "\n(note: the shell can only write inside the job folder. use write_file or move_file for files elsewhere.)"
        }
        let statusLine = stopReason ?? "exit code \(shellProcess.terminationStatus)"
        return "\(statusLine)\n\(outputText)"
    }

    /// Kills a process and everything it started (pip, npm, ffmpeg…), children first.
    nonisolated private static func terminateProcessTree(rootProcessIdentifier: Int32) {
        let childListProcess = Process()
        childListProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        childListProcess.arguments = ["-P", String(rootProcessIdentifier)]
        let childListPipe = Pipe()
        childListProcess.standardOutput = childListPipe
        try? childListProcess.run()
        childListProcess.waitUntilExit()
        let childListText = String(data: childListPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for childIdentifierText in childListText.split(separator: "\n") {
            if let childIdentifier = Int32(childIdentifierText.trimmingCharacters(in: .whitespaces)) {
                terminateProcessTree(rootProcessIdentifier: childIdentifier)
            }
        }
        kill(rootProcessIdentifier, SIGKILL)
    }

    /// Moves a file the user asked to organize. Never overwrites; never touches private folders.
    private func moveFile(from sourcePathText: String, to destinationPathText: String) -> String {
        let sourceURL = resolvePath(sourcePathText)
        var destinationURL = resolvePath(destinationPathText)
        if isPrivatePath(sourceURL) || isPrivatePath(destinationURL) { return "that location is private to this mac." }
        if !isWritableLocation(sourceURL) || !isWritableLocation(destinationURL) {
            return "i can only move files within the job folder, Desktop, Documents, Downloads, Pictures, Movies, Music or ~/Orchestra."
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            destinationURL = destinationURL.appendingPathComponent(sourceURL.lastPathComponent)
        }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return "\(destinationURL.path) already exists; pick another name."
        }
        do {
            try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
            return "moved to \(destinationURL.path)"
        } catch {
            return "couldn't move: \(error.localizedDescription)"
        }
    }

    // MARK: - Logging

    private func writeAgentLog() {
        let logText = agentLogLines.joined(separator: "\n") + "\n"
        try? logText.write(to: jobFolderURL.appendingPathComponent("agent-log.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func compactJSON(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static func todayText() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter.string(from: Date())
    }

    // MARK: - Function declarations

    /// JSON schema for a tool whose parameters are all strings.
    private static func stringParameters(_ parameterNames: [String], required requiredParameterNames: [String]) -> [String: Any] {
        var properties: [String: Any] = [:]
        for parameterName in parameterNames {
            properties[parameterName] = ["type": "string"]
        }
        return ["type": "object", "properties": properties, "required": requiredParameterNames]
    }

    private static let functionDeclarations: [[String: Any]] = [
        [
            "name": "run_shell",
            "description": "Run a zsh command on the user's Mac (sandboxed: it can read most files but can only write inside the job folder, temp and caches; no credentials). Returns exit code and output (last 12k chars). 60 s timeout. Use for converting files, python, curl, git in the job folder, etc.",
            "parameters": stringParameters(["command"], required: ["command"])
        ],
        [
            "name": "read_file",
            "description": "Read a text file. Relative paths are inside the job folder; ~/ means the user's home.",
            "parameters": stringParameters(["path"], required: ["path"])
        ],
        [
            "name": "write_file",
            "description": "Write a text file (creates folders). Deliverables go in output/. Outside the job folder it never overwrites an existing file.",
            "parameters": stringParameters(["path", "content"], required: ["path", "content"])
        ],
        [
            "name": "list_folder",
            "description": "List a folder's visible items.",
            "parameters": stringParameters(["path"], required: ["path"])
        ],
        [
            "name": "find_files",
            "description": "Find files anywhere on the Mac by name using Spotlight (fast; don't walk Desktop/Documents/Downloads by hand).",
            "parameters": stringParameters(["name"], required: ["name"])
        ],
        [
            "name": "open",
            "description": "Show the user something: open a file in its app or a https link in their browser.",
            "parameters": stringParameters(["target"], required: ["target"])
        ],
        [
            "name": "mac_action",
            "description": "Run one Orchestra Mac action, e.g. 'spotify play lofi playlist', 'open_app Notes', 'volume 30', 'key cmd+s'.",
            "parameters": stringParameters(["action"], required: ["action"])
        ],
        [
            "name": "move_file",
            "description": "Move or rename one of the user's files or folders (e.g. organizing Downloads). Never overwrites. The shell itself can only write inside the job folder.",
            "parameters": stringParameters(["from", "to"], required: ["from", "to"])
        ],
        [
            "name": "update_note",
            "description": "Replace note.md, the live page the user watches while you work. Markdown: '# title', a one-line answer/status, then '- [ ] step' / '- [x] step' plan boxes (mark the current one with ' ← now'), then results. Call it at the start and after each stage.",
            "parameters": stringParameters(["markdown"], required: ["markdown"])
        ],
        [
            "name": "finish",
            "description": "End the job. 'answer' is read aloud and saved as report.md: lead with the result in 2-3 plain sentences, then files you made (full paths), then any questions.",
            "parameters": stringParameters(["answer"], required: ["answer"])
        ]
    ]

    private static let agentSystemPrompt = """
    you are orchestra's background agent, working on the user's mac to finish one job the user asked for by voice. you have tools for the shell, files, spotlight, opening things, mac actions, and a live note page.

    how to work:
    - first call update_note with a title, one status line, and a 3-5 step plan as checkboxes. update it as each stage finishes.
    - take the most direct route. find files with find_files (spotlight) instead of walking desktop, documents or downloads.
    - deliverables go in output/, scratch in tmp/. the shell can't write outside the job folder: use write_file to save a file elsewhere (never overwrites) and move_file to organize the user's files. you can't delete the user's files — list what should go and ask them. if a python library is missing, install it into the job folder: run_shell "python3 -m pip install --target tmp/pylib <pkg>" then run with PYTHONPATH=tmp/pylib (installing into ~ is blocked).
    - make it exactly as asked and check it before saying it's done (open it, re-read it, recompute numbers).
    - the request is the approval for normal work. ask first (by finishing with a question) only before deleting or overwriting the user's files outside the job folder, sending or posting anything to other people, or spending money. anything you'd send is a draft.
    - never claim you did something unless a tool result shows it. never invent facts, files, prices or links.
    - never script clicks in apps. if a step needs clicking around an app's window, finish and say the user can ask orchestra to take over the screen for that step.
    - when done, set the note's status line to the result, tick the boxes, then call finish.
    """
}

/// Thread-safe buffer for shell output read on a background queue.
final class ShellOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collectedData = Data()
    private let maximumByteCount = 2_000_000

    func append(_ newData: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard collectedData.count < maximumByteCount else { return }
        collectedData.append(newData)
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: collectedData, as: UTF8.self)
    }
}

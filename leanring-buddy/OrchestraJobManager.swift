//
//  OrchestraJobManager.swift
//  leanring-buddy
//
//  Background "jobs" handed to Hermes, HeyClicky-style. When the voice
//  model decides a request is real work (research, files, installs,
//  multi-step tasks), it emits a [JOB: ...] tag and this manager:
//
//    1. makes a job folder in ~/Orchestra/Jobs/<date>-<slug>/ with
//       brief.md (what was asked) and memory.md (goal + rules),
//    2. sends the brief to Hermes through the MCP bridge,
//    3. polls hermes_task_status until it finishes,
//    4. writes report.md with Hermes's answer, updates ~/Orchestra/Jobs/WORK.md,
//       and tells the user (spoken line + macOS notification).
//
//  The job list survives restarts (jobs.json), and unfinished jobs resume
//  polling on launch.
//

import AppKit
import Combine
import Foundation
import UserNotifications

enum OrchestraJobState: String, Codable {
    case sending
    case running
    case done
    case failed
}

struct OrchestraJob: Codable, Identifiable, Equatable {
    let id: String
    var title: String
    let brief: String
    let createdAt: Date
    var folderPath: String
    var hermesTaskIdentifier: String?
    var state: OrchestraJobState
    var resultText: String?
    var finishedAt: Date?
    /// Where the job runs. Optional so jobs.json from older builds still loads (nil = hermes).
    var place: OrchestraJobPlace?
    /// Set when a routine started this job.
    var routineIdentifier: String?
    /// Quick looks speak Hermes's answer itself instead of "your job is done".
    var isQuickLook: Bool?

    var folderURL: URL { URL(fileURLWithPath: folderPath, isDirectory: true) }
    var noteFileURL: URL { folderURL.appendingPathComponent("note.md") }
    var runsOnMac: Bool { place == .mac }
}

@MainActor
final class OrchestraJobManager: ObservableObject {
    @Published private(set) var jobs: [OrchestraJob] = []
    @Published private(set) var routines: [OrchestraRoutine] = []

    /// Set by CompanionManager so Mac jobs can use the same actions as voice.
    var macActionRunner: MacActionRunner?
    private var macAgentTasksByJobIdentifier: [String: Task<Void, Never>] = [:]
    private var routineSchedulerTimer: Timer?

    /// Called with a short spoken line when a job finishes (e.g. "your flight
    /// research is done"). CompanionManager wires this to text-to-speech.
    var onJobFinishedAnnouncement: (@MainActor (String) -> Void)?

    private let hermesBridgeClient = HermesBridgeClient()
    private var pollingTasksByJobIdentifier: [String: Task<Void, Never>] = [:]
    private let pollingIntervalSeconds: UInt64 = 15
    /// Hermes tasks are capped at 900 s on the bridge; poll a little past that.
    private let maximumPollingDurationSeconds: TimeInterval = 20 * 60

    static let jobsRootFolderURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Orchestra", isDirectory: true)
        .appendingPathComponent("Jobs", isDirectory: true)

    private var jobsIndexFileURL: URL { Self.jobsRootFolderURL.appendingPathComponent("jobs.json") }
    private var workListFileURL: URL { Self.jobsRootFolderURL.appendingPathComponent("WORK.md") }
    private var routinesFileURL: URL { Self.jobsRootFolderURL.appendingPathComponent("routines.json") }

    init() {
        try? FileManager.default.createDirectory(at: Self.jobsRootFolderURL, withIntermediateDirectories: true)
        loadJobsIndex()
        loadRoutines()
    }

    // MARK: - Lifecycle

    func resumeUnfinishedJobs() {
        requestNotificationPermissionIfNeeded()
        for job in jobs where job.state == .running {
            if job.runsOnMac {
                // The Mac agent lives in this process, so it died with the app.
                updateJob(job.id) { job in
                    job.state = .failed
                    job.resultText = "orchestra quit while this job was running. ask again to restart it; what it made is in the job folder."
                }
            } else if job.hermesTaskIdentifier != nil {
                startPolling(jobIdentifier: job.id)
            }
        }
        startRoutineScheduler()
        for job in jobs where job.state == .sending {
            // The app quit before Hermes got the job; mark it so the user can retry.
            updateJob(job.id) { job in
                job.state = .failed
                job.resultText = "orchestra closed before this job reached hermes. ask again to retry."
            }
        }
    }

    // MARK: - Starting a job

    /// Creates the job folder and hands the brief to Hermes (cloud/accounts work)
    /// or to the on-Mac agent (Mac files and apps). Returns the job so the
    /// caller can mention its title.
    @discardableResult
    func startJob(brief: String,
                  spokenRequest: String,
                  place: OrchestraJobPlace = .hermes,
                  routineIdentifier: String? = nil,
                  isQuickLook: Bool = false) -> OrchestraJob {
        let createdAt = Date()
        let jobTitle = isQuickLook
            ? "quick look: " + Self.makeShortTitle(from: brief.components(separatedBy: ": ").dropFirst().joined(separator: ": "))
            : Self.makeShortTitle(from: brief)
        let folderName = "\(Self.folderDateFormatter.string(from: createdAt))-\(Self.makeSlug(from: jobTitle))"
        let jobFolderURL = Self.jobsRootFolderURL.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: jobFolderURL, withIntermediateDirectories: true)

        let job = OrchestraJob(
            id: folderName,
            title: jobTitle,
            brief: brief,
            createdAt: createdAt,
            folderPath: jobFolderURL.path,
            hermesTaskIdentifier: nil,
            state: place == .mac ? .running : .sending,
            resultText: nil,
            finishedAt: nil,
            place: place,
            routineIdentifier: routineIdentifier,
            isQuickLook: isQuickLook
        )
        jobs.insert(job, at: 0)
        writeBriefAndMemoryFiles(for: job, spokenRequest: spokenRequest)
        saveJobsIndex()

        if place == .mac {
            startMacAgent(for: job, spokenRequest: spokenRequest)
            return job
        }

        let hermesPrompt = makeHermesPrompt(for: job, spokenRequest: spokenRequest)
        Task {
            do {
                let hermesTaskIdentifier = try await hermesBridgeClient.startTask(prompt: hermesPrompt, timeoutSeconds: 900)
                updateJob(job.id) { job in
                    job.hermesTaskIdentifier = hermesTaskIdentifier
                    job.state = .running
                }
                startPolling(jobIdentifier: job.id)
            } catch {
                finishJob(jobIdentifier: job.id, succeeded: false,
                          resultText: "couldn't reach hermes: \(error.localizedDescription)")
            }
        }
        return job
    }

    // MARK: - Mac agent

    private func startMacAgent(for job: OrchestraJob, spokenRequest: String) {
        let initialNote = "# \(job.title)\n\nstarting…\n"
        try? initialNote.write(to: job.noteFileURL, atomically: true, encoding: .utf8)
        macAgentTasksByJobIdentifier[job.id] = Task { [weak self] in
            guard let self else { return }
            let smartModelName = await GeminiAPI.resolveSmartModel()
            let agentRunner = MacAgentJobRunner(
                jobFolderURL: job.folderURL,
                brief: job.brief,
                spokenRequest: spokenRequest,
                geminiAPI: GeminiAPI(model: smartModelName),
                macActionRunner: self.macActionRunner ?? MacActionRunner()
            )
            let outcome = await agentRunner.run()
            // If the user pressed Stop, cancelJob already wrote the result; don't overwrite it.
            if Task.isCancelled { return }
            self.macAgentTasksByJobIdentifier[job.id] = nil
            self.finishJob(jobIdentifier: job.id, succeeded: outcome.succeeded, resultText: outcome.finalAnswer)
        }
    }

    /// Stops a running job (Mac agent or Hermes task).
    func cancelJob(_ job: OrchestraJob) {
        macAgentTasksByJobIdentifier[job.id]?.cancel()
        macAgentTasksByJobIdentifier[job.id] = nil
        pollingTasksByJobIdentifier[job.id]?.cancel()
        if let hermesTaskIdentifier = job.hermesTaskIdentifier, !job.runsOnMac {
            Task { try? await hermesBridgeClient.cancelTask(taskIdentifier: hermesTaskIdentifier) }
        }
        finishJob(jobIdentifier: job.id, succeeded: false, resultText: "you stopped this job.")
    }

    // MARK: - Polling

    private func startPolling(jobIdentifier: String) {
        pollingTasksByJobIdentifier[jobIdentifier]?.cancel()
        pollingTasksByJobIdentifier[jobIdentifier] = Task { [weak self] in
            guard let self else { return }
            let pollingStartedAt = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self.pollingIntervalSeconds * 1_000_000_000)
                guard let job = self.jobs.first(where: { $0.id == jobIdentifier }),
                      let hermesTaskIdentifier = job.hermesTaskIdentifier else { return }

                do {
                    let status = try await self.hermesBridgeClient.taskStatus(taskIdentifier: hermesTaskIdentifier)
                    if status.isFinished {
                        let resultText = status.didSucceed
                            ? status.outputText
                            : (status.errorText ?? status.outputText).isEmpty ? "hermes stopped without an answer (\(status.state))." : (status.errorText ?? status.outputText)
                        self.finishJob(jobIdentifier: jobIdentifier, succeeded: status.didSucceed, resultText: resultText)
                        return
                    }
                } catch {
                    // Network blips are normal (laptop asleep, tunnel restarting); keep trying.
                    print("⚠️ Orchestra job poll failed: \(error.localizedDescription)")
                }

                if Date().timeIntervalSince(job.createdAt) > self.maximumPollingDurationSeconds,
                   Date().timeIntervalSince(pollingStartedAt) > 60 {
                    self.finishJob(jobIdentifier: jobIdentifier, succeeded: false,
                                   resultText: "no answer from hermes after 20 minutes. it may still be working; check hermes.")
                    return
                }
            }
        }
    }

    private func finishJob(jobIdentifier: String, succeeded: Bool, resultText: String) {
        // A job finishes once: later calls (a cancelled agent returning, a late poll) are ignored.
        if let existingJob = jobs.first(where: { $0.id == jobIdentifier }),
           existingJob.state == .done || existingJob.state == .failed {
            return
        }
        pollingTasksByJobIdentifier[jobIdentifier] = nil
        updateJob(jobIdentifier) { job in
            job.state = succeeded ? .done : .failed
            job.resultText = resultText
            job.finishedAt = Date()
        }
        guard let job = jobs.first(where: { $0.id == jobIdentifier }) else { return }
        writeReportFile(for: job)
        writeNoteResult(for: job)
        writeWorkList()

        let announcement: String
        if job.isQuickLook == true {
            announcement = succeeded
                ? String(resultText.prefix(700))
                : "hermes couldn't check that just now."
        } else {
            announcement = succeeded
                ? "your job, \(job.title), is done. open it from the jobs list to see the note."
                : "heads up, your job, \(job.title), didn't finish."
        }
        onJobFinishedAnnouncement?(announcement)
        postNotification(title: succeeded ? "Job done: \(job.title)" : "Job failed: \(job.title)",
                         body: String(resultText.prefix(220)))
    }

    // MARK: - Context for the voice model

    /// A few lines about recent jobs, added to the voice prompt so the user
    /// can ask "how's my job going?" or "what did hermes find?".
    func recentJobsSummaryForPrompt() -> String {
        let recentJobs = jobs.prefix(5)
        guard !recentJobs.isEmpty else { return "no jobs yet." }
        return recentJobs.map { job in
            var line = "- \(job.title) [\(job.state.rawValue), \(job.runsOnMac ? "mac" : "hermes")], started \(Self.relativeDateFormatter.localizedString(for: job.createdAt, relativeTo: Date()))"
            if let resultText = job.resultText, job.state == .done || job.state == .failed {
                line += ". result: \(resultText.prefix(500))"
            }
            return line
        }.joined(separator: "\n")
    }

    func openJobFolder(_ job: OrchestraJob) {
        NSWorkspace.shared.open(job.folderURL)
    }

    /// Opens the live note window for a job (falls back to the folder).
    func openJobNote(_ job: OrchestraJob) {
        if FileManager.default.fileExists(atPath: job.noteFileURL.path) {
            JobNoteWindowManager.shared.showNote(for: job, jobManager: self)
        } else {
            openJobFolder(job)
        }
    }

    func openJobsRootFolder() {
        NSWorkspace.shared.open(Self.jobsRootFolderURL)
    }

    func resetHermesConnection() {
        Task { await hermesBridgeClient.resetConnection() }
    }

    // MARK: - Hermes prompt

    private func makeHermesPrompt(for job: OrchestraJob, spokenRequest: String) -> String {
        let relatedEarlierJobs = jobs
            .filter { $0.id != job.id && $0.state == .done }
            .prefix(5)
            .map { "- \($0.title): \(($0.resultText ?? "").prefix(200))" }
            .joined(separator: "\n")

        return """
        Job from the user's Orchestra Mac app. The user asked by voice; Orchestra wrote this brief.

        Job: \(job.title)
        Brief: \(job.brief)
        the user's exact words: "\(spokenRequest)"

        How to work:
        - Work out what the user actually wants and do it with your own tools (shell, browser, web, files).
        - If part of it depends on something only the user knows (an account, a link, their own details), do everything else first, then list one short bundled set of questions at the end. Never invent their facts or use dummy data.
        - The request is the approval for normal work. Ask first (as a question in your reply) only before deleting or overwriting their data, sending or posting anything to other people, or spending money. Anything you'd send is a draft until the user approves it.
        - Only say you did something (sent, saved, installed, booked) if a tool result in this run shows it. If you couldn't confirm it, say so.
        - Check your work before saying it's done.

        Your final reply is read aloud and saved as the job report, so:
        - Lead with the result in two or three plain sentences.
        - Then list any files you made (full paths on your machine) and links.
        - Then any questions for the user. No filler.
        \(relatedEarlierJobs.isEmpty ? "" : "\nEarlier finished jobs (reuse them, don't redo them):\n\(relatedEarlierJobs)")
        """
    }

    // MARK: - Files

    private func writeBriefAndMemoryFiles(for job: OrchestraJob, spokenRequest: String) {
        let briefText = """
        # \(job.title)

        Started: \(Self.readableDateFormatter.string(from: job.createdAt))

        ## What the user said
        \(spokenRequest)

        ## Brief sent to Hermes
        \(job.brief)
        """
        try? briefText.write(to: job.folderURL.appendingPathComponent("brief.md"), atomically: true, encoding: .utf8)

        let memoryText = """
        # Memory
        Goal: \(job.title)
        Rules: confirm before deleting, sending to other people, or spending money. Never store passwords or tokens here.
        Progress: see report.md when the job finishes.
        """
        try? memoryText.write(to: job.folderURL.appendingPathComponent("memory.md"), atomically: true, encoding: .utf8)
    }

    private func writeReportFile(for job: OrchestraJob) {
        let reportText = """
        # \(job.title) — \(job.state == .done ? "done" : "failed")

        Started: \(Self.readableDateFormatter.string(from: job.createdAt))
        Finished: \(Self.readableDateFormatter.string(from: job.finishedAt ?? Date()))
        Hermes task: \(job.hermesTaskIdentifier ?? "none")

        \(job.resultText ?? "")
        """
        try? reportText.write(to: job.folderURL.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
    }

    /// Hermes jobs don't write a note while they run, so give them one at the end.
    /// Mac jobs keep the agent's note and get the final answer added on top.
    private func writeNoteResult(for job: OrchestraJob) {
        let existingNote = (try? String(contentsOf: job.noteFileURL, encoding: .utf8)) ?? ""
        let resultSection = "**\(job.state == .done ? "done" : "didn't finish")** — \(job.resultText ?? "")"
        let updatedNote: String
        if existingNote.isEmpty || !job.runsOnMac {
            updatedNote = "# \(job.title)\n\n\(resultSection)\n"
        } else {
            var noteLines = existingNote.components(separatedBy: "\n")
            let insertIndex = noteLines.first?.hasPrefix("#") == true ? 1 : 0
            noteLines.insert(contentsOf: ["", resultSection], at: insertIndex)
            updatedNote = noteLines.joined(separator: "\n")
        }
        try? updatedNote.write(to: job.noteFileURL, atomically: true, encoding: .utf8)
    }

    private func writeWorkList() {
        let lines = jobs.map { job in
            "- \(Self.readableDateFormatter.string(from: job.createdAt)) · \(job.title) · \(job.state.rawValue) · \(job.id)/"
        }
        let workListText = "# Orchestra jobs\n\n" + lines.joined(separator: "\n") + "\n"
        try? workListText.write(to: workListFileURL, atomically: true, encoding: .utf8)
    }

    private func loadJobsIndex() {
        guard let data = try? Data(contentsOf: jobsIndexFileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        jobs = (try? decoder.decode([OrchestraJob].self, from: data)) ?? []
    }

    private func saveJobsIndex() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(jobs) else { return }
        try? data.write(to: jobsIndexFileURL, options: .atomic)
    }

    private func updateJob(_ jobIdentifier: String, change: (inout OrchestraJob) -> Void) {
        guard let jobIndex = jobs.firstIndex(where: { $0.id == jobIdentifier }) else { return }
        change(&jobs[jobIndex])
        saveJobsIndex()
    }

    // MARK: - Routines (repeating jobs)

    /// Adds a routine. Returns nil if the schedule text can't be understood.
    @discardableResult
    func addRoutine(scheduleText: String, place: OrchestraJobPlace, brief: String) -> OrchestraRoutine? {
        guard OrchestraRoutineSchedule(text: scheduleText) != nil else { return nil }
        let routine = OrchestraRoutine(
            id: UUID().uuidString,
            title: Self.makeShortTitle(from: brief),
            brief: brief,
            place: place,
            scheduleText: scheduleText,
            createdAt: Date(),
            lastRunAt: nil,
            isPaused: false
        )
        routines.append(routine)
        saveRoutines()
        return routine
    }

    /// Removes routines whose title or brief contains the words given.
    /// Returns the titles removed.
    func removeRoutines(matching searchText: String) -> [String] {
        let searchWords = searchText.lowercased().split(separator: " ").map(String.init).filter { $0.count > 2 }
        let matchingRoutines = routines.filter { routine in
            let haystack = (routine.title + " " + routine.brief).lowercased()
            return searchWords.isEmpty ? false : searchWords.allSatisfy { haystack.contains($0) }
        }
        routines.removeAll { routine in matchingRoutines.contains(where: { $0.id == routine.id }) }
        saveRoutines()
        return matchingRoutines.map(\.title)
    }

    func removeRoutine(_ routine: OrchestraRoutine) {
        routines.removeAll { $0.id == routine.id }
        saveRoutines()
    }

    func routinesSummaryForPrompt() -> String {
        guard !routines.isEmpty else { return "no routines yet." }
        return routines.map { routine in
            "- \(routine.title) [\(routine.scheduleText), runs on \(routine.place.rawValue)\(routine.isPaused ? ", paused" : "")]"
        }.joined(separator: "\n")
    }

    private func startRoutineScheduler() {
        routineSchedulerTimer?.invalidate()
        routineSchedulerTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runDueRoutines() }
        }
        runDueRoutines()
    }

    private func runDueRoutines() {
        let now = Date()
        for routine in routines where routine.isDue(now: now) {
            if let routineIndex = routines.firstIndex(where: { $0.id == routine.id }) {
                routines[routineIndex].lastRunAt = now
            }
            saveRoutines()
            startJob(brief: routine.brief,
                     spokenRequest: "(routine: \(routine.scheduleText)) \(routine.brief)",
                     place: routine.place,
                     routineIdentifier: routine.id)
        }
    }

    private func loadRoutines() {
        guard let data = try? Data(contentsOf: routinesFileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        routines = (try? decoder.decode([OrchestraRoutine].self, from: data)) ?? []
    }

    private func saveRoutines() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(routines) else { return }
        try? data.write(to: routinesFileURL, options: .atomic)
    }

    // MARK: - Notifications

    private func requestNotificationPermissionIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Naming helpers

    /// First sentence of the brief, trimmed to a short title.
    private static func makeShortTitle(from brief: String) -> String {
        let firstSentence = brief
            .components(separatedBy: CharacterSet(charactersIn: ".\n"))
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? brief
        let words = firstSentence.split(separator: " ").prefix(8)
        let title = words.joined(separator: " ")
        return title.isEmpty ? "untitled job" : title.lowercased()
    }

    private static func makeSlug(from title: String) -> String {
        let allowedCharacters = CharacterSet.alphanumerics
        let slug = title.lowercased()
            .unicodeScalars
            .map { allowedCharacters.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { partialSlug, character in
                if character == "-" && partialSlug.hasSuffix("-") { return }
                partialSlug.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(slug.prefix(40)).isEmpty ? "job" : String(slug.prefix(40))
    }

    private static let folderDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    private static let readableDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

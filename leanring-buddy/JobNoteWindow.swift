//
//  JobNoteWindow.swift
//  leanring-buddy
//
//  The live "note" page for a job — Orchestra's version of HeyClicky's
//  paper note. The Mac agent rewrites note.md as it works (title, status
//  line, plan checkboxes, results); this window re-reads the file every
//  second so the user can watch it fill in. Hermes jobs get their note when
//  they finish.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class JobNoteWindowManager {
    static let shared = JobNoteWindowManager()

    private var noteWindowsByJobIdentifier: [String: NSWindow] = [:]

    func showNote(for job: OrchestraJob, jobManager: OrchestraJobManager) {
        if let existingWindow = noteWindowsByJobIdentifier[job.id] {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let noteWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        noteWindow.title = job.title
        noteWindow.titlebarAppearsTransparent = true
        noteWindow.isReleasedWhenClosed = false
        noteWindow.level = .floating
        noteWindow.center()
        noteWindow.contentView = NSHostingView(rootView: JobNoteView(jobIdentifier: job.id, jobManager: jobManager))

        // Forget the window when it closes so the next open makes a fresh one.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: noteWindow, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.noteWindowsByJobIdentifier[job.id] = nil }
        }

        noteWindowsByJobIdentifier[job.id] = noteWindow
        noteWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct JobNoteView: View {
    let jobIdentifier: String
    @ObservedObject var jobManager: OrchestraJobManager

    @State private var noteMarkdown: String = ""
    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var job: OrchestraJob? {
        jobManager.jobs.first(where: { $0.id == jobIdentifier })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(noteMarkdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, noteLine in
                        noteLineView(noteLine)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 34)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }

            Divider()

            HStack(spacing: 10) {
                if let job {
                    Circle()
                        .fill(job.state == .done ? Color.green : (job.state == .failed ? Color.red : Color.orange))
                        .frame(width: 7, height: 7)
                    Text(job.state == .running || job.state == .sending ? "working on \(job.runsOnMac ? "your mac" : "hermes")…" : job.state.rawValue)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    if job.state == .running || job.state == .sending {
                        Button("Stop") { jobManager.cancelJob(job) }
                            .pointerCursor()
                    }
                    Button("Open Folder") { jobManager.openJobFolder(job) }
                        .pointerCursor()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 360, minHeight: 360)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear(perform: reloadNote)
        .onReceive(refreshTimer) { _ in reloadNote() }
    }

    private func reloadNote() {
        guard let job else { return }
        let latestNoteMarkdown = (try? String(contentsOf: job.noteFileURL, encoding: .utf8)) ?? ""
        if latestNoteMarkdown != noteMarkdown {
            withAnimation(.easeOut(duration: 0.25)) {
                noteMarkdown = latestNoteMarkdown
            }
        }
    }

    /// A tiny markdown renderer for the shapes the agent writes: headings,
    /// checkboxes, bullets, and paragraphs with inline **bold**/links.
    @ViewBuilder
    private func noteLineView(_ noteLine: String) -> some View {
        let trimmedLine = noteLine.trimmingCharacters(in: .whitespaces)
        if trimmedLine.hasPrefix("# ") {
            Text(inlineMarkdown(String(trimmedLine.dropFirst(2))))
                .font(.system(size: 22, weight: .bold))
                .padding(.bottom, 4)
        } else if trimmedLine.hasPrefix("## ") {
            Text(inlineMarkdown(String(trimmedLine.dropFirst(3))))
                .font(.system(size: 16, weight: .semibold))
                .padding(.top, 6)
        } else if trimmedLine.hasPrefix("### ") {
            Text(inlineMarkdown(String(trimmedLine.dropFirst(4))))
                .font(.system(size: 14, weight: .semibold))
        } else if trimmedLine.hasPrefix("- [ ] ") || trimmedLine.hasPrefix("- [x] ") || trimmedLine.hasPrefix("- [X] ") {
            let isChecked = !trimmedLine.hasPrefix("- [ ] ")
            let itemText = String(trimmedLine.dropFirst(6))
            let isCurrentStep = itemText.contains("← now")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isChecked ? "checkmark.square.fill" : (isCurrentStep ? "arrow.right.square" : "square"))
                    .foregroundColor(isChecked ? .green : (isCurrentStep ? .orange : .secondary))
                Text(inlineMarkdown(itemText.replacingOccurrences(of: "← now", with: "")))
                    .strikethrough(isChecked, color: .secondary)
                    .foregroundColor(isChecked ? .secondary : .primary)
                    .fontWeight(isCurrentStep ? .semibold : .regular)
            }
            .font(.system(size: 13))
        } else if trimmedLine.hasPrefix("- ") || trimmedLine.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundColor(.secondary)
                Text(inlineMarkdown(String(trimmedLine.dropFirst(2))))
            }
            .font(.system(size: 13))
        } else if trimmedLine.isEmpty {
            Spacer().frame(height: 2)
        } else {
            Text(inlineMarkdown(trimmedLine))
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

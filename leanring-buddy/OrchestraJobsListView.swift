//
//  OrchestraJobsListView.swift
//  leanring-buddy
//
//  The "Jobs" block in the menu bar panel: the last few jobs handed to
//  Hermes, their status, and a click to open each job's folder. It's its
//  own view so it can observe OrchestraJobManager directly (the panel only
//  observes CompanionManager, which wouldn't refresh on job changes).
//

import SwiftUI

struct OrchestraJobsListView: View {
    @ObservedObject var orchestraJobManager: OrchestraJobManager

    private let maximumVisibleJobCount = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Jobs")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Button(action: {
                    orchestraJobManager.openJobsRootFolder()
                }) {
                    Text("Open folder")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            if orchestraJobManager.jobs.isEmpty {
                Text("Ask for real work (\"research…\", \"make me a…\") and I'll hand it to Hermes.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(orchestraJobManager.jobs.prefix(maximumVisibleJobCount)) { job in
                    jobRow(for: job)
                }
            }

            if !orchestraJobManager.routines.isEmpty {
                Text("Repeating")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.top, 4)
                ForEach(orchestraJobManager.routines) { routine in
                    HStack(spacing: 6) {
                        Image(systemName: "repeat")
                            .font(.system(size: 9))
                            .foregroundColor(DS.Colors.textTertiary)
                        Text(routine.title)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(routine.scheduleText)
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                        Button(action: {
                            orchestraJobManager.removeRoutine(routine)
                        }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .help("Stop repeating")
                    }
                }
            }
        }
    }

    private func jobRow(for job: OrchestraJob) -> some View {
        Button(action: {
            orchestraJobManager.openJobNote(job)
        }) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor(for: job.state))
                    .frame(width: 6, height: 6)
                Image(systemName: job.runsOnMac ? "laptopcomputer" : "cloud")
                    .font(.system(size: 9))
                    .foregroundColor(DS.Colors.textTertiary)
                Text(job.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(statusLabel(for: job.state))
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(job.resultText ?? job.brief)
    }

    private func statusLabel(for jobState: OrchestraJobState) -> String {
        switch jobState {
        case .sending: return "sending"
        case .running: return "working"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    private func statusColor(for jobState: OrchestraJobState) -> Color {
        switch jobState {
        case .sending, .running: return Color.orange
        case .done: return Color.green
        case .failed: return Color.red
        }
    }
}

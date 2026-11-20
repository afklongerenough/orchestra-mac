//
//  HomeWindow.swift
//  leanring-buddy
//
//  Orchestra's Home: a normal, resizable window (alongside the menu-bar
//  panel) with a sidebar — the main Orchestra chat, the agent roster and
//  the jobs — and a box to type instead of talk.
//

import AppKit
import SwiftUI

@MainActor
final class HomeWindowManager {
    static let shared = HomeWindowManager()
    private var homeWindow: NSWindow?

    func showHomeWindow(companionManager: CompanionManager) {
        if homeWindow == nil {
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            newWindow.title = "Orchestra"
            newWindow.isReleasedWhenClosed = false
            newWindow.minSize = NSSize(width: 640, height: 420)
            newWindow.contentView = NSHostingView(rootView: HomeView(companionManager: companionManager,
                                                                     agentStore: OrchestraAgentStore.shared,
                                                                     orchestraJobManager: companionManager.orchestraJobManager))
            newWindow.center()
            newWindow.setFrameAutosaveName("OrchestraHomeWindow")
            homeWindow = newWindow
        }
        // A menu-bar app has to activate itself for its window to come forward.
        NSApp.activate(ignoringOtherApps: true)
        homeWindow?.makeKeyAndOrderFront(nil)
    }
}

private enum HomeSidebarItem: Hashable {
    case orchestraChat
    case agent(String)
    case jobs
}

struct HomeView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var agentStore: OrchestraAgentStore
    @ObservedObject var orchestraJobManager: OrchestraJobManager
    @State private var selectedSidebarItem: HomeSidebarItem? = .orchestraChat
    @State private var agentSearchText = ""

    private var filteredAgents: [OrchestraAgent] {
        let searchText = agentSearchText.trimmingCharacters(in: .whitespaces).lowercased()
        let visibleAgents = agentStore.agents.filter { !$0.isArchived || !searchText.isEmpty }
        guard !searchText.isEmpty else { return visibleAgents }
        return visibleAgents.filter { $0.displayName.lowercased().contains(searchText) || $0.purpose.lowercased().contains(searchText) }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSidebarItem) {
                Label("Orchestra", systemImage: "waveform").tag(HomeSidebarItem.orchestraChat)
                Section("Agents") {
                    TextField("Search agents", text: $agentSearchText)
                        .textFieldStyle(.roundedBorder)
                    ForEach(filteredAgents) { agent in
                        Label(agent.displayName + (agent.isArchived ? " (archived)" : ""),
                              systemImage: agent.place == .mac ? "laptopcomputer" : "cloud")
                            .tag(HomeSidebarItem.agent(agent.id))
                    }
                    if agentStore.agents.isEmpty {
                        Text("Say \"make me a study agent\"").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Work") {
                    Label("Jobs", systemImage: "tray.full").tag(HomeSidebarItem.jobs)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            switch selectedSidebarItem {
            case .agent(let agentIdentifier):
                if let agent = agentStore.agents.first(where: { $0.id == agentIdentifier }) {
                    HomeAgentDetailView(agent: agent, agentStore: agentStore, orchestraJobManager: orchestraJobManager)
                } else {
                    Text("Agent not found").foregroundStyle(.secondary)
                }
            case .jobs:
                ScrollView {
                    OrchestraJobsListView(orchestraJobManager: orchestraJobManager)
                        .padding(20)
                }
            default:
                HomeChatView(companionManager: companionManager)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}

/// The main conversation: what was said or typed, newest at the bottom.
struct HomeChatView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var typedMessageText = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if companionManager.chatMessages.isEmpty {
                            Text("Talk with Control+Option, say \"hey clicky\", or type below.")
                                .foregroundStyle(.secondary)
                                .padding(.top, 40)
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(companionManager.chatMessages) { chatMessage in
                            HomeChatBubble(chatMessage: chatMessage).id(chatMessage.id)
                        }
                    }
                    .padding(20)
                }
                .onChange(of: companionManager.chatMessages.count) { _ in
                    if let lastMessage = companionManager.chatMessages.last {
                        withAnimation { scrollProxy.scrollTo(lastMessage.id, anchor: .bottom) }
                    }
                }
                .onAppear {
                    if let lastMessage = companionManager.chatMessages.last {
                        scrollProxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Type to Orchestra…", text: $typedMessageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .onSubmit(sendTypedMessage)
                Button("Send", action: sendTypedMessage)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(typedMessageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
        .navigationTitle("Orchestra")
    }

    private func sendTypedMessage() {
        let messageText = typedMessageText
        typedMessageText = ""
        companionManager.sendTypedMessage(messageText)
    }
}

private struct HomeChatBubble: View {
    let chatMessage: CompanionManager.ChatMessage

    var body: some View {
        HStack {
            if chatMessage.isFromUser { Spacer(minLength: 60) }
            VStack(alignment: chatMessage.isFromUser ? .trailing : .leading, spacing: 3) {
                Text(chatMessage.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(chatMessage.isFromUser ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.15)))
                    .foregroundColor(chatMessage.isFromUser ? .white : .primary)
                Text(chatMessage.date, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !chatMessage.isFromUser { Spacer(minLength: 60) }
        }
    }
}

/// One agent: its purpose, memory, history, and a box to give it a job.
struct HomeAgentDetailView: View {
    let agent: OrchestraAgent
    @ObservedObject var agentStore: OrchestraAgentStore
    @ObservedObject var orchestraJobManager: OrchestraJobManager
    @State private var jobRequestText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(agent.displayName).font(.title2.weight(.semibold))
                            Text(agent.purpose).foregroundStyle(.secondary)
                            Text("Works on \(agent.place == .mac ? "this Mac" : "Hermes")").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open folder") { agentStore.openFolder(of: agent) }
                        Button(agent.isArchived ? "Unarchive" : "Archive") {
                            agentStore.setArchived(agent, isArchived: !agent.isArchived)
                        }
                    }
                    GroupBox("Memory") {
                        Text(agentStore.memoryText(of: agent))
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("Recent history") {
                        Text(agentStore.recentHistoryText(of: agent, maximumCharacters: 5000))
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    let agentJobs = orchestraJobManager.jobs.filter { $0.agentIdentifier == agent.id }.prefix(8)
                    if !agentJobs.isEmpty {
                        GroupBox("Jobs") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(agentJobs)) { agentJob in
                                    HStack {
                                        Text(agentJob.title).lineLimit(1)
                                        Spacer()
                                        Text(agentJob.state.rawValue).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(20)
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Give \(agent.displayName) a job…", text: $jobRequestText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .onSubmit(startAgentJob)
                Button("Start", action: startAgentJob)
                    .disabled(jobRequestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
        .navigationTitle(agent.displayName)
    }

    private func startAgentJob() {
        let requestText = jobRequestText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestText.isEmpty else { return }
        jobRequestText = ""
        orchestraJobManager.startJob(brief: requestText, spokenRequest: requestText, place: agent.place, agentIdentifier: agent.id)
    }
}

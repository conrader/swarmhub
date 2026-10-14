import SwiftUI
import UIKit
import SwarmHubCore

struct ChatView: View {
    let agentID: String
    @Environment(MobileStore.self) private var store
    @State private var showSessions = false
    @State private var showDetails = false
    private var profile: AgentProfile? { store.profiles.first { $0.id == agentID } }
    private var cache: ChatCache { store.caches[agentID] ?? ChatCache() }
    private var running: Bool { store.activeAgents.contains(agentID) }
    var body: some View {
        Group {
            if let profile {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            if store.demo { AvailabilityNote(text: "Local sample conversation. No message is sent to a server.") }
                            if profile.sessionID == nil {
                                ContentUnavailableView {
                                    Label("Choose a conversation", systemImage: "bubble.left")
                                } description: {
                                    Text("Open an existing server session to continue the same conversation, or start a new one.")
                                } actions: {
                                    Button("Choose session") { showSessions = true }.buttonStyle(.borderedProminent)
                                }
                            }
                            ForEach(cache.messages.filter { $0.role != .system }) { message in
                                MessageRow(message: message, agent: profile)
                            }
                            if let turn = cache.turn {
                                if turn.state == .interrupted {
                                    AvailabilityNote(text: "The result is not confirmed. The agent may still be working. This request has not been resent.")
                                    Button("Check server status") { Task { await store.refresh(agentID) } }.buttonStyle(.bordered)
                                }
                                MessageRow(message: .init(id: turn.id, role: .user, text: turn.input), agent: profile)
                                if !turn.output.isEmpty {
                                    MessageRow(message: .init(id: turn.id + ":output", role: .assistant, text: turn.output), agent: profile)
                                }
                                Text(turn.state == .interrupted ? "Partial turn · saved on this phone" : "Waiting for the server’s final state…").font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(store.approvals.filter { $0.agentID == agentID }) { item in
                                NavigationLink { ApprovalDetailView(item: item) } label: {
                                    Label(item.request.title, systemImage: "checkmark.shield").padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                }.background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                            }
                            if let notice = store.notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
                            Color.clear.frame(height: 1).id("latest-message")
                        }.padding(20)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: cache.turn?.output) { proxy.scrollTo("latest-message", anchor: .bottom) }
                    .onChange(of: cache.messages.count) { proxy.scrollTo("latest-message", anchor: .bottom) }
                }
                .safeAreaInset(edge: .bottom) { composer }
                .navigationTitle(profile.name).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Button { showDetails = true } label: {
                            HStack(spacing: 8) { AgentMark(color: profile.color, size: 28); Text(profile.name).font(.headline) }
                        }.accessibilityLabel("Details for \(profile.name)")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Sessions", systemImage: "bubble.left.and.bubble.right") { showSessions = true }
                            .disabled(running || cache.turn != nil)
                    }
                }
                .toolbar(.hidden, for: .tabBar)
                .sheet(isPresented: $showSessions) { SessionPickerView(agentID: agentID) }
                .sheet(isPresented: $showDetails) { AgentDetailsView(agentID: agentID) }
                .task { await store.refresh(agentID) }
            } else { EmptyDestination(title: "Agent unavailable", symbol: "person.crop.circle.badge.questionmark", description: "This profile is no longer configured on this phone.") }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if running || cache.turn?.runID != nil {
                HStack {
                    if running { ProgressView().controlSize(.small) }
                    Text(running ? "Agent is working" : "Outcome needs checking").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if store.capabilities[agentID]?.stop == true, cache.turn?.runID != nil {
                        Button("Stop") { Task { await store.stop(agentID) } }.font(.subheadline).padding(.vertical, 8)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message \(profile?.name ?? "agent")…", text: Binding(get: { cache.draft }, set: { store.updateDraft($0, agentID: agentID) }), axis: .vertical)
                    .lineLimit(1...6).padding(10).accessibilityLabel("Message")
                Button { Task { await store.send(agentID) } } label: {
                    Image(systemName: "arrow.up").font(.headline).frame(width: 44, height: 44)
                }.buttonStyle(.borderedProminent).clipShape(Circle()).accessibilityLabel("Send message")
                    .disabled(running || cache.turn != nil || profile?.sessionID == nil || store.capabilities[agentID]?.sessions != true || cache.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(6).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 25))
        }.padding(.horizontal, 14).padding(.vertical, 10).background(.background)
    }
}

private struct MessageRow: View {
    let message: TranscriptMessage
    let agent: AgentProfile
    private var user: Bool { message.role == .user }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !user {
                HStack(spacing: 7) { AgentMark(color: agent.color, size: 20); Text(agent.name).font(.caption).foregroundStyle(.secondary) }
            }
            Text(message.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .padding(user ? 13 : 0)
                .background { if user { RoundedRectangle(cornerRadius: 18).fill(.quaternary) } }
                .contextMenu { Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text } }
        }.padding(.leading, user ? 36 : 0)
            .accessibilityElement(children: .combine).accessibilityLabel("\(user ? "You" : agent.name): \(message.text)")
    }
}

import SwiftUI

/// Above the message box of a bot whose agent waits at a question in its terminal: who waits and since when, what
/// its terminal shows, and one button that opens that terminal (`AppStore+HerdrPrompt.swift`). The reply's own line
/// ("Codex is waiting for you in its terminal") only said that it waits; this says for what, and gets the person
/// there. The card goes when the agent moves again.
struct HerdrPromptCard: View {
    @EnvironmentObject private var store: AppStore; @ObservedObject var bot: Bot
    var group: GroupChat? = nil
    @State private var terminal = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let prompt = store.herdrPrompt(for: bot, in: group)
        Group {
            if let prompt { card(prompt).transition(.opacity.combined(with: .move(edge: .bottom))) }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: prompt != nil)
        // What the terminal shows is read again while the card is on screen, so it follows a second question.
        .task(id: prompt?.since) {
            guard prompt != nil, store.launchWorkEnabled else { return }
            while !Task.isCancelled {
                await store.refreshHerdrPrompt(for: bot, in: group)
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
            }
        }
    }

    private func card(_ prompt: HerdrPrompt) -> some View {
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "hand.raised.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(AppColor.caution)
                    .frame(width: 30, height: 30).background(Circle().fill(AppColor.caution.opacity(0.16))).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(group == nil ? prompt.title : "\(bot.name) · \(prompt.title)").font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 4) {
                        Text(prompt.detailText)
                        Text("Since") + Text(" ") + Text(prompt.since, style: .time) + Text(".")
                    }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let agent = prompt.agent {
                    Button(prompt.actionTitle) { terminal = true }
                        .buttonStyle(.appleProminent).accessibilityIdentifier("chat.prompt.answer")
                        .sheet(isPresented: $terminal) {
                            HerdrTerminalSheet(bot: bot, agent: agent, group: group)
                        }
                }
            }
            if let origin = prompt.origin { Text(origin).font(.caption).textSelection(.enabled) }
            if let review = prompt.reviewDescription { Text(review).font(.caption) }
            if !prompt.question.isEmpty {
                ScrollView(.vertical) {
                    Text(prompt.question).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.primary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .frame(maxHeight: 190).fixedSize(horizontal: false, vertical: true)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel("What its terminal shows: \(prompt.question)")
            } else if prompt.agent != nil {
                Text(HerdrPrompt.unread).font(.caption).foregroundStyle(.secondary)
            }
        }
        .chatCard(tint: bot.colours)
        .accessibilityElement(children: .contain).accessibilityLabel(prompt.title)
    }
}

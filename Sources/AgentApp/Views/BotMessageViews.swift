import SwiftUI

/// P34: a bot's small avatar by profile name; a bot SwarmHub does not have gets its initial in a circle.
struct BotMark: View {
    @EnvironmentObject private var store: AppStore
    let profile: String; var size: CGFloat = 16
    var body: some View {
        if let bot = store.bot(forProfile: profile) {
            BotAvatar(bot: bot, size: size)
        } else {
            Circle().fill(AppColor.raised).frame(width: size, height: size)
                .overlay(Text(profile.prefix(1).uppercased()).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.secondary))
        }
    }
}

/// D4: "<avatar> → Infra" on a bot-msg step and under the reply; click opens the thread. P41: "Asked Infra…" while the
/// step waits, "Infra replied" once it answered.
struct BotMessageChip: View {
    @EnvironmentObject private var store: AppStore
    let key: BotThreadKey; var state = BotMessageChipState.sent
    var body: some View {
        let name = store.displayName(forProfile: key.to)
        Button { store.openThread(key) } label: {
            HStack(spacing: 4) {
                BotMark(profile: key.to, size: 14)
                Text(BotMessageCopy.chip(name, state)).font(.caption.weight(.medium))
            }.padding(.leading, 3).padding(.trailing, 7).padding(.vertical, 2)
            .background(AppColor.card, in: Capsule()).overlay(Capsule().stroke(AppColor.separator, lineWidth: 0.5)).contentShape(Capsule())
        }.buttonStyle(.plain).help("Open the thread with \(store.displayName(forProfile: key.to))")
    }
}

extension AppStore {
    /// The thread a bot-msg step belongs to: its `--from`, else the bot whose reply holds the step.
    func threadKey(for call: BotMessageCall, in message: ChatMessage) -> BotThreadKey? {
        guard let from = call.from ?? bots.first(where: { bot in bot.messages.contains { $0.id == message.id } }).map(profile(of:)) else { return nil }
        return BotThreadKey(from: from, to: call.to, session: call.session)
    }
}

/// The recipients a reply wrote to, one chip each, under its text.
struct BotMessageChipsRow: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var message: ChatMessage
    var body: some View {
        // Each recipient once, with its latest step's state.
        let chips = (message.activity?.steps ?? []).compactMap { step in step.botMessage.flatMap { store.threadKey(for: $0, in: message) }.map { (key: $0, step: step) } }
            .reduce(into: [(key: BotThreadKey, step: ToolStep)]()) { list, item in
                if let index = list.firstIndex(where: { $0.key == item.key }) { list[index] = item } else { list.append(item) }
            }
        if !chips.isEmpty {
            HStack(spacing: 6) {
                ForEach(chips, id: \.key) { BotMessageChip(key: $0.key, state: store.chipState(for: $0.step, key: $0.key, streaming: message.isStreaming)) }
            }
        }
    }
}

/// D6: "<avatar> Jarvis wrote to Infra · Open conversation" in the recipient’s chat (P41: also above an open side thread).
struct BotArrivalLine: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var message: ChatMessage
    var body: some View {
        // P42: once its exchange is read, the line is the whole card.
        if BotExchangeCard.isExchange(message) { BotExchangeCard(message: message) } else { line }
    }
    @ViewBuilder private var line: some View {
        let from = message.metadata[BotMessageKey.from] ?? "", to = message.metadata[BotMessageKey.to] ?? ""
        HStack(spacing: 6) {
            BotMark(profile: from, size: 16)
            Text(message.content).foregroundStyle(.secondary)
            Text("·").foregroundStyle(.tertiary)
            Button(BotMessageCopy.openThread) { store.openThread(BotThreadKey(from: from, to: to)) }.buttonStyle(.link)
            Text(message.createdAt, style: .time).foregroundStyle(.tertiary)
        }.font(.caption).padding(.vertical, 4)
    }
}

/// D5: both avatars, the thread oldest to newest (newest at the bottom), refreshed while open. Opens with what is
/// known (loaded before, or the sender's steps), then fills from the recipient.
struct BotThreadSheet: View {
    @EnvironmentObject private var store: AppStore; @Environment(\.dismiss) private var dismiss
    @ObservedObject var center: BotMessageCenter
    let key: BotThreadKey
    var refresh: Duration = .seconds(4)
    var body: some View {
        let lines = store.knownThreadLines(key)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                BotMark(profile: key.from, size: 26)
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                BotMark(profile: key.to, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(BotMessageCopy.paletteTitle(store.displayName(forProfile: key.from), store.displayName(forProfile: key.to))).font(.headline)
                    Text(key.session.map { "Oneshot session \($0) in \(store.displayName(forProfile: key.to))" } ?? "Thread “From \(key.from)” in \(store.displayName(forProfile: key.to))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if lines.isEmpty { Text(BotMessageCopy.empty).font(.caption).foregroundStyle(.secondary).padding(.top, 20) }
                        ForEach(lines) { line in ThreadBubble(line: line, outgoing: line.author == key.from).id(line.id) }
                        if store.readableRecipient(key) == nil && !lines.isEmpty {
                            Text(BotMessageCopy.notConnected).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: lines.last?.id) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } } }
            }
        }.frame(width: 520, height: 560).background(AppColor.panel)
        .task(id: key) {
            while !Task.isCancelled {
                await store.loadThread(key)
                try? await Task.sleep(for: refresh)
            }
        }
    }
}

private struct ThreadBubble: View {
    @EnvironmentObject private var store: AppStore
    let line: BotThreadLine; let outgoing: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if outgoing { Spacer(minLength: 60) } else { BotMark(profile: line.author, size: 22) }
            VStack(alignment: outgoing ? .trailing : .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(store.displayName(forProfile: line.author)).font(.caption.weight(.semibold))
                    if let date = line.date {
                        Text(date, format: Calendar.current.isDateInToday(date) ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                // P42: the steps the recipient ran for this answer, then its text.
                if let activity = line.activity, activity.total > 0 { ThreadSteps(activity: activity) }
                if !line.text.isEmpty {
                    Text(line.text).textSelection(.enabled).padding(.horizontal, 11).padding(.vertical, 7)
                        .background(outgoing ? AppColor.raised : AppColor.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            if outgoing { BotMark(profile: line.author, size: 22) } else { Spacer(minLength: 60) }
        }
    }
}

/// D7: the Activity tab's "Bot messages": every thread involving this bot, newest first.
struct BotMessagesSection: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    @ObservedObject var center: BotMessageCenter
    var body: some View {
        let threads = store.threadSummaries(for: bot)
        VStack(alignment: .leading, spacing: 8) {
            Text(BotMessageCopy.sectionTitle).font(.headline)
            ForEach(threads) { thread in
                Button { store.openThread(thread.key) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        HStack(spacing: -5) { BotMark(profile: thread.key.from, size: 22); BotMark(profile: thread.key.to, size: 22) }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(BotMessageCopy.paletteTitle(store.displayName(forProfile: thread.key.from), store.displayName(forProfile: thread.key.to)))
                                    .font(.caption.weight(.medium))
                                Spacer()
                                if let date = thread.date { Text(date, format: .relative(presentation: .numeric)).font(.caption2).foregroundStyle(.secondary) }
                            }
                            if !thread.lastLine.isEmpty { Text(thread.lastLine).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                        }
                    }.padding(8).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if threads.isEmpty { Text(BotMessageCopy.empty).font(.caption).foregroundStyle(.secondary) }
            // P41: a failed session list is one quiet line, not silence.
            if let problem = center.errors[bot.id] { Text(BotMessageCopy.pollFailed(problem)).font(.caption2).foregroundStyle(.tertiary).lineLimit(2) }
        }
    }
}

/// P42: an answer's steps in the conversation sheet: "Running a command · df -h", one per line, the running one marked.
struct ThreadSteps: View {
    let activity: ToolActivity
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(ActivityCopy.steps(activity.total)).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            ForEach(Array(activity.steps.enumerated()), id: \.offset) { _, step in
                HStack(spacing: 5) {
                    if step.isRunning { ProgressView().controlSize(.mini) } else { Image(systemName: step.failed ? "exclamationmark.triangle.fill" : "checkmark").font(.system(size: 8)).foregroundStyle(step.failed ? .orange : .secondary) }
                    Text(ActivityCopy.label(step.name)).font(.caption2)
                    if let preview = step.preview { Text(preview).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle) }
                }
            }
        }.padding(.horizontal, 10).padding(.vertical, 6).background(AppColor.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

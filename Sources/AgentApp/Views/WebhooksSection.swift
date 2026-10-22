import SwiftUI

/// Routines tab: the agent's webhook routines on its box (list, create with a key shown once, new key, delete) and
/// whether the box's loopback receiver answers. Hermes on this Mac loads on appear; a box loads on a click, because
/// each call is a short management turn there.
struct WebhooksSection: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    @ObservedObject var cache: WebhooksCache
    @State private var creating = false
    @State private var confirming: String?

    var body: some View {
        let state = cache.state(for: bot.id)
        let busy = state.busy != nil
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(WebhookCopy.title).font(.headline); Spacer()
                if busy { ProgressView().controlSize(.mini).help(WebhookCopy.working) }
                Button { Task { await store.refreshWebhooks(for: bot) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).disabled(busy).help(WebhookCopy.refresh).accessibilityLabel(WebhookCopy.refresh)
                Button { creating = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).disabled(busy || state.panel == nil).help(WebhookCopy.newWebhook).accessibilityLabel(WebhookCopy.newWebhook)
            }
            if let error = state.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let notice = state.notice { Text(notice).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if let panel = state.panel {
                WebhookReceiverRow(status: panel.receiver, busy: busy) { Task { await store.startWebhookReceiver(for: bot) } }
                ForEach(panel.webhooks) { hook in
                    WebhookRow(hook: hook, busy: busy, confirming: $confirming,
                               rotate: { Task { await store.rotateWebhookKey(hook, for: bot) } },
                               delete: { Task { await store.deleteWebhook(hook, for: bot) } })
                }
                if panel.webhooks.isEmpty { Text(WebhookCopy.empty).font(.caption).foregroundStyle(.secondary) }
                if panel.webhooks.contains(where: \.isLoopbackOnly) { Text(WebhookCopy.loopbackNote).font(.caption2).foregroundStyle(.tertiary) }
            } else if !busy {
                Button(WebhookCopy.load) { Task { await store.refreshWebhooks(for: bot) } }.controlSize(.small)
                if !store.webhooksAreLocal(bot) { Text(WebhookCopy.loadCaption).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .sheet(item: sheet) { target in WebhookSheetView(bot: bot, cache: cache, initial: target) }
        .task(id: bot.id) {
            if cache.autoLoad, store.webhooksAreLocal(bot), cache.state(for: bot.id).panel == nil { await store.refreshWebhooks(for: bot) }
        }
    }
}

extension WebhooksSection {
    /// A pending reveal (kept by the store, so a slow box call survives leaving the tab) wins over the name form;
    /// closing either forgets the key.
    private var sheet: Binding<WebhookSheet?> {
        Binding(get: {
            if let reveal = cache.state(for: bot.id).reveal { return .reveal(reveal) }
            return creating ? .create : nil
        }, set: { value in
            guard value == nil else { return }
            creating = false
            store.dismissWebhookReveal(for: bot)
        })
    }
}

enum WebhookSheet: Identifiable {
    case create, reveal(WebhookReveal)
    var id: String { if case .reveal(let reveal) = self { reveal.id.uuidString } else { "create" } }
}

struct WebhookReceiverRow: View {
    let status: WebhookReceiverStatus
    let busy: Bool
    let start: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(status.running ? Color.green : Color.red).frame(width: 7, height: 7)
                Text(status.running ? WebhookCopy.receiverRunning(status.listen) : WebhookCopy.receiverDown).font(.caption)
                Spacer()
                if !status.running, status.manager != "none" {
                    Button(WebhookCopy.startReceiver, action: start).font(.caption).buttonStyle(.plain).disabled(busy)
                }
            }
            if !status.running { Text(status.detail).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
        }
    }
}

private struct WebhookRow: View {
    let hook: BoxWebhook
    let busy: Bool
    @Binding var confirming: String?
    let rotate: () -> Void, delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(hook.routine).fontWeight(.medium).lineLimit(1)
            HStack(spacing: 6) {
                Text(hook.url).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 0)
                Button { copyToPasteboard(hook.url) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help(WebhookCopy.copyAddress).accessibilityLabel(WebhookCopy.copyAddress)
            }
            Text(WebhookRowCopy.detail(hook)).font(.caption2).foregroundStyle(.tertiary)
            HStack(spacing: 12) {
                if confirming == "rotate:" + hook.id || confirming == "delete:" + hook.id {
                    let deleting = confirming == "delete:" + hook.id
                    Text(deleting ? WebhookCopy.deleteConfirm : WebhookCopy.rotateConfirm).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button(WebhookCopy.cancel) { confirming = nil }
                    Button(deleting ? WebhookCopy.delete : WebhookCopy.rotate) { confirming = nil; deleting ? delete() : rotate() }.foregroundStyle(.red)
                } else {
                    Button(WebhookCopy.rotate) { confirming = "rotate:" + hook.id }
                    Spacer()
                    Button(WebhookCopy.delete) { confirming = "delete:" + hook.id }.foregroundStyle(.secondary)
                }
            }.font(.caption).buttonStyle(.plain).disabled(busy)
        }.padding(10).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 9))
    }
}

enum WebhookRowCopy {
    /// "Called 3 times · key changed 2 hours ago"; the key part only once it was replaced after creation.
    static func detail(_ hook: BoxWebhook, now: Date = .now) -> String {
        var parts = [WebhookCopy.calls(hook.fired ?? 0)]
        if let created = hook.created, let rotated = hook.rotated, rotated - created > 1 {
            let formatter = RelativeDateTimeFormatter(); formatter.unitsStyle = .full
            parts.append(WebhookCopy.keyChanged(formatter.localizedString(for: Date(timeIntervalSince1970: rotated), relativeTo: now)))
        }
        return parts.joined(separator: " · ")
    }
}

import SwiftUI

/// New webhook: a name; once the box confirms, the section swaps this for the reveal (address and key, shown once
/// with copy buttons). A new key opens straight on the reveal. Closing the reveal forgets the key.
struct WebhookSheetView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var bot: Bot
    @ObservedObject var cache: WebhooksCache
    let initial: WebhookSheet
    @State private var name = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let reveal = initialReveal {
                WebhookRevealView(reveal: reveal)
                HStack { Spacer(); Button(WebhookCopy.done) { dismiss() }.keyboardShortcut(.defaultAction) }
            } else {
                Text(WebhookCopy.newWebhook).font(.headline)
                TextField(WebhookCopy.name, text: $name, prompt: Text(WebhookCopy.namePlaceholder)).onSubmit(create)
                Text(WebhookCopy.nameHint).font(.caption).foregroundStyle(.secondary)
                if let error = cache.state(for: bot.id).error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                HStack {
                    if working { ProgressView().controlSize(.small); Text(WebhookCopy.working).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button(WebhookCopy.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(WebhookCopy.create, action: create).keyboardShortcut(.defaultAction)
                        .disabled(working || !WebhookCommand.validName(name.trimmingCharacters(in: .whitespaces)))
                }
            }
        }.padding(20).frame(width: 460)
    }

    private var initialReveal: WebhookReveal? { if case .reveal(let reveal) = initial { reveal } else { nil } }

    private func create() {
        let routine = name.trimmingCharacters(in: .whitespaces)
        guard !working, WebhookCommand.validName(routine) else { return }
        working = true
        Task {
            _ = await store.createWebhook(routine, for: bot)
            working = false
        }
    }
}

struct WebhookRevealView: View {
    let reveal: WebhookReveal

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(reveal.rotated ? WebhookCopy.rotated : WebhookCopy.created).font(.headline)
            Text(reveal.routine).foregroundStyle(.secondary)
            field(WebhookCopy.address, reveal.url, copy: WebhookCopy.copyAddress)
            field(WebhookCopy.key, reveal.key, copy: WebhookCopy.copyKey)
            Text(WebhookCopy.headerLine).font(.caption).foregroundStyle(.secondary)
            Button(WebhookCopy.copyExample) { copyToPasteboard(reveal.curl) }.controlSize(.small)
            Label(WebhookCopy.onceWarning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        }
    }

    private func field(_ label: String, _ value: String, copy: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(value).font(.system(.callout, design: .monospaced)).textSelection(.enabled).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 6))
                Button { copyToPasteboard(value) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help(copy).accessibilityLabel(copy)
            }
        }
    }
}

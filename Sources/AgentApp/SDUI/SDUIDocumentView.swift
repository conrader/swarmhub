import SwiftUI
import SwarmHubCore

/// Renders one decoded view document natively (P7b). Everything comes from `SDUIRenderer.tree`; every string is drawn
/// as plain text (`Text(verbatim:)`), or for `markdown` as inline styling with links removed
/// (`SDUIRenderText.inline`), so nothing in a document or in bound data becomes a link. Behaviour (flow moves,
/// confirmations, refusals, form values, busy) is the shared `SDUIInteraction`, the same on iOS (P7c); `open_url`
/// runs only through the router's allowlist and the confirmation below.
struct SDUIDocumentView: View {
    let document: SDUIDocument
    let data: SDUIData
    let actions: SDUIActions
    @State private var interaction = SDUIInteraction()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let root = interaction.tree(document, data: data) { SDUINodeView(node: root, context: context) }
            if let failure = interaction.failure { Text(verbatim: failure).font(.caption).foregroundStyle(.red) }
        }
        .confirmationDialog(Text(verbatim: interaction.confirmation?.request.title ?? ""), isPresented: confirming,
                            titleVisibility: .visible, presenting: interaction.confirmation) { pending in
            Button { resolve(pending, accepted: true) } label: { Text(verbatim: pending.request.button) }
            Button(role: .cancel) { resolve(pending, accepted: false) } label: { Text(verbatim: "Cancel") }
        } message: { pending in
            if !pending.request.message.isEmpty { Text(verbatim: pending.request.message) }
        }
    }

    private var confirming: Binding<Bool> {
        Binding(get: { interaction.confirmation != nil }, set: { if !$0 { interaction.dismissConfirmation() } })
    }

    private var context: SDUINodeContext {
        SDUINodeContext(
            busy: interaction.busy,
            isAvailable: { action, flow in SDUIInteraction.isAvailable(action, flow: flow, actions: actions) },
            press: { action, label, flow in run(interaction.press(action, label: label, flow: flow, router: actions.router)) },
            submit: { form in run(interaction.submit(form, router: actions.router)) },
            value: { form, field in interaction.value(form, field) },
            setValue: { form, field, value in interaction.setValue(value, form: form, field: field) },
            problems: { form in interaction.problems(form) },
            step: { flow in interaction.step(flow) })
    }

    private func resolve(_ pending: SDUIInteraction.Pending, accepted: Bool) {
        run(interaction.resolve(pending, accepted: accepted))
    }

    private func run(_ command: SDUIAppCommand?) {
        guard let command, interaction.start(command, actions: actions) else { return }
        Task {
            let failure = await actions.perform(command)
            interaction.finish(failure: failure)
        }
    }
}

struct SDUINodeContext {
    let busy: Bool
    let isAvailable: @MainActor (SDUIResolvedAction, SDUIFlowPosition?) -> Bool
    let press: @MainActor (SDUIResolvedAction, String, SDUIFlowPosition?) -> Void
    let submit: @MainActor (SDUIRenderForm) -> Void
    let value: @MainActor (SDUIRenderForm, String) -> SDUIFieldValue
    let setValue: @MainActor (SDUIRenderForm, String, SDUIFieldValue) -> Void
    let problems: @MainActor (SDUIRenderForm) -> [String: String]
    let step: @MainActor (SDUIFlowPosition) -> Int
}

struct SDUINodeView: View {
    let node: SDUIRenderNode
    let context: SDUINodeContext
    var flow: SDUIFlowPosition? = nil

    var body: some View {
        switch node.element {
        case .text(let text, let style, let role):
            SDUITextView(text: text, style: style, role: role)
        case .badge(let text, let tone):
            Text(verbatim: text).font(.caption.weight(.semibold)).foregroundStyle(Self.color(tone))
                .padding(.horizontal, 7).padding(.vertical, 2).background(Self.color(tone).opacity(0.14), in: Capsule())
        case .keyValue(let pairs):
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                ForEach(pairs.indices, id: \.self) { index in
                    GridRow {
                        Text(verbatim: pairs[index].key).foregroundStyle(.secondary)
                        Text(verbatim: pairs[index].value)
                    }
                }
            }.font(.caption)
        case .list(let children, let style):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(children.enumerated()), id: \.element.key) { index, child in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        switch style {
                        case .plain: EmptyView()
                        case .bulleted: Text(verbatim: "•").foregroundStyle(.secondary)
                        case .numbered: Text(verbatim: "\(index + 1).").foregroundStyle(.secondary).monospacedDigit()
                        }
                        SDUINodeView(node: child, context: context, flow: flow)
                    }
                }
            }
        case .card(let title, let subtitle, let children):
            VStack(alignment: .leading, spacing: 6) {
                if let title { Text(verbatim: title).font(.callout.weight(.semibold)) }
                if let subtitle { Text(verbatim: subtitle).font(.caption2).foregroundStyle(.tertiary) }
                ForEach(children, id: \.key) { SDUINodeView(node: $0, context: context, flow: flow) }
            }.padding(12).frame(maxWidth: 500, alignment: .leading).background(AppColor.card, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(AppColor.separator, lineWidth: 0.5))
        case .form(let form):
            SDUIFormView(form: form, context: context)
        case .button(let label, let action, let style):
            SDUIButton(label: label, style: style, enabled: !context.busy && context.isAvailable(action, flow)) {
                context.press(action, label, flow)
            }
        case .flow(_, let steps):
            let position = SDUIFlowPosition(key: node.key, count: steps.count)
            let index = context.step(position)
            if steps.indices.contains(index) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: steps[index].title).font(.headline)
                    ForEach(steps[index].children, id: \.key) { SDUINodeView(node: $0, context: context, flow: position) }
                }.id(steps[index].id)
            }
        case .progress(let total, let value, let label):
            VStack(alignment: .leading, spacing: 3) {
                if let label { Text(verbatim: label).font(.caption).foregroundStyle(.secondary) }
                if let value { ProgressView(value: Double(value), total: Double(total)) } else { ProgressView().progressViewStyle(.linear) }
            }
        case .diffPreview(let title, let lines, let count):
            VStack(alignment: .leading, spacing: 4) {
                if let title { Text(verbatim: title).font(.caption.weight(.semibold)) }
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(lines.indices, id: \.self) { Text(verbatim: lines[$0]).foregroundStyle(Self.diffColor(lines[$0])) }
                    }.font(.system(.caption, design: .monospaced)).padding(6)
                }.background(AppColor.raised, in: RoundedRectangle(cornerRadius: 6))
                if count > lines.count { Text(verbatim: "\(count - lines.count) more lines").font(.caption2).foregroundStyle(.tertiary) }
            }
        }
    }

    static func color(_ tone: SDUITone) -> Color {
        switch tone {
        case .neutral: .secondary
        case .info: .accentColor
        case .success: .green
        case .warning: .orange
        case .danger: .red
        }
    }

    static func diffColor(_ line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red }
        return .primary
    }
}

/// Plain text verbatim; `markdown` as inline styling with every link removed. Never selectable, so no data detector
/// or text-view link handling can apply either.
struct SDUITextView: View {
    let text: String
    let style: SDUITextStyle
    let role: SDUITextRole

    var body: some View {
        Group {
            switch style {
            case .plain: Text(verbatim: text)
            case .markdown: Text(SDUIRenderText.inline(text))
            }
        }.font(font).foregroundStyle(role == .caption || role == .footnote ? Color.secondary : Color.primary).lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var font: Font {
        switch role {
        case .body: .callout
        case .title: .title3.weight(.semibold)
        case .headline: .headline
        case .caption: .caption
        case .footnote: .footnote
        case .monospace: .system(.callout, design: .monospaced)
        }
    }
}

struct SDUIButton: View {
    let label: String
    let style: SDUIButtonStyle
    let enabled: Bool
    let action: @MainActor () -> Void

    var body: some View {
        switch style {
        case .primary: Button(action: action) { Text(verbatim: label) }.buttonStyle(.borderedProminent).controlSize(.small).disabled(!enabled)
        case .secondary: Button(action: action) { Text(verbatim: label) }.buttonStyle(.bordered).controlSize(.small).disabled(!enabled)
        case .destructive:
            Button(role: .destructive, action: action) { Text(verbatim: label) }.buttonStyle(.bordered).controlSize(.small).disabled(!enabled)
        }
    }
}

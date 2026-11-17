import SwiftUI

/// Installing skills from a repository, in two steps as the server does it: first one field for the repository, and
/// the server downloads and checks it; then the skills it found, each with what the security check said, to tick and
/// install. What passed is ticked. A skill the check blocked can only be ticked through "Install anyway…", which
/// asks first and says what it means. A bot can be asked for a second opinion; it is told to read and report.
struct HerdrLibraryInstallSheet: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var model: HerdrLibraryModel
    let server: HerdrServer
    var height: CGFloat = HerdrLibraryInstallSheet.size.height
    static let size = CGSize(width: 700, height: 680)

    var body: some View {
        VStack(spacing: 0) {
            switch model.install {
            case .closed: EmptyView()
            case .asking: ask(working: false, problem: nil)
            case .inspecting: ask(working: true, problem: nil)
            case .failed(let why): ask(working: false, problem: why)
            case .found(let inspection): found(inspection, installing: false)
            case .installing(let inspection): found(inspection, installing: true)
            }
        }
        .frame(width: Self.size.width, height: height).background(AppColor.panel)
        .sheet(item: model.question(at: .install)) { question in LibraryConfirmSheet(model: model, question: question, server: server) }
    }

    // MARK: The repository

    private func ask(working: Bool, problem: String?) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 26) {
                HeroHeader(title: HerdrLibraryCopy.installTitle, detail: HerdrLibraryCopy.installDetail) {
                    SymbolTile(symbol: "square.and.arrow.down.fill", colour: AppColor.sage, size: 64)
                }
                VStack(alignment: .leading, spacing: 14) {
                    StandaloneField(title: HerdrLibraryCopy.installField, text: $model.installSource, prompt: HerdrLibraryCopy.installPrompt, monospaced: true, submit: inspect)
                        .disabled(working)
                    if working { StatusCard(kind: .working, title: HerdrLibraryCopy.inspecting, detail: HerdrLibraryCopy.inspectingDetail) }
                    if let problem { StatusCard(kind: .warning, title: "The repository could not be checked", detail: problem) }
                }
                .frame(maxWidth: AppleMetrics.column)
            }
            .padding(.horizontal, 32).frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 10) {
                Button("Cancel") { Task { await model.cancelInstall() } }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(HerdrLibraryCopy.inspect, action: inspect).buttonStyle(.appleProminent).keyboardShortcut(.defaultAction)
                    .disabled(working || model.installSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.large).padding(.horizontal, 24).padding(.vertical, 16)
        }
    }

    private func inspect() { Task { await model.inspect() } }

    // MARK: What was found

    private func found(_ inspection: HerdrInstallInspection, installing: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                SymbolTile(symbol: "shippingbox.fill", colour: AppColor.sage, size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(HerdrLibraryCopy.found(inspection)).font(.title2.bold()).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                    Text(HerdrLibraryCopy.foundDetail(inspection)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24).padding(.vertical, 18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if inspection.skills.isEmpty {
                        EmptyNote(symbol: "tray", title: "No skills in this repository", detail: "skillshare found nothing to install there.", colour: AppColor.olive)
                    }
                    ForEach(inspection.skills) { skill in LibraryFoundSkillCard(model: model, inspection: inspection, skill: skill, installing: installing) }
                    if let note = model.installNote {
                        StatusCard(kind: note.isProblem ? .warning : .good, title: note.text)
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 18).frame(maxWidth: .infinity, alignment: .topLeading)
            }
            Divider()
            HStack(spacing: 10) {
                Button("Cancel") { Task { await model.cancelInstall() } }.keyboardShortcut(.cancelAction).disabled(installing)
                reviewMenu.disabled(installing)
                Spacer()
                if installing { ProgressView().controlSize(.small); Text("Installing…").font(.callout).foregroundStyle(.secondary) }
                Button(HerdrLibraryCopy.install(model.installPlan.skills.count)) { Task { await model.installChosen() } }
                    .buttonStyle(.appleProminent).disabled(installing || model.installPlan.skills.isEmpty)
            }
            .controlSize(.large).padding(.horizontal, 24).padding(.vertical, 16)
        }
    }

    /// A second opinion: the bots on this server, one of which gets the audit to read and report on.
    @ViewBuilder private var reviewMenu: some View {
        let bots = store.herdrBots(on: server).filter { !$0.isReadOnlyArchive }
        if !bots.isEmpty {
            Menu {
                ForEach(bots) { bot in Button(bot.name) { askForReview(bot) } }
            } label: { Label("Ask a bot to review", systemImage: "bubble.left.and.text.bubble.right") }
            .fixedSize()
        }
    }

    /// Hands the audit to the bot as a message in its chat, the way any message is sent. The bot is told to read and
    /// report, and not to install.
    private func askForReview(_ bot: Bot) {
        guard let request = model.reviewRequest else { return }
        let sent = store.send(text: request, bot: bot, conversation: bot, replyToID: nil, waitWhenFull: true)
        model.reviewAsked(of: bot.name, sent: sent)
    }
}

/// One found skill: what it is, what the security check said about it in a sentence, its findings when it has any,
/// and whether it is ticked.
private struct LibraryFoundSkillCard: View {
    @ObservedObject var model: HerdrLibraryModel
    let inspection: HerdrInstallInspection
    let skill: HerdrInstallInspection.Found
    let installing: Bool

    var body: some View {
        let blocked = inspection.isBlocked(skill), chosen = model.chosen.contains(skill.name), can = model.canChoose(skill), forced = model.forced.contains(skill.name)
        VStack(alignment: .leading, spacing: 12) {
            Button { model.toggle(skill) } label: {
                HStack(alignment: .top, spacing: 12) {
                    SymbolTile(symbol: mark(blocked).symbol, colour: mark(blocked).colour, size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(HerdrLibraryCopy.readable(skill.name)).font(.headline).foregroundStyle(.primary)
                            if skill.installed { FactChip(text: HerdrLibraryCopy.replaces, symbol: "arrow.triangle.2.circlepath") }
                        }
                        if let description = skill.description, !description.isEmpty {
                            Text(description).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                        }
                        Text(HerdrLibraryCopy.audit(skill, blocked: blocked)).font(.callout.weight(.medium))
                            .foregroundStyle(blocked ? AnyShapeStyle(AppColor.caution) : skill.audited && skill.findings.isEmpty ? AnyShapeStyle(AppColor.good) : AnyShapeStyle(.secondary))
                            .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading).padding(.top, 1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: !can ? "nosign" : chosen ? "checkmark.circle.fill" : "circle").font(.system(size: 18))
                        .foregroundStyle(chosen && can ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(.tertiary)).accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!can || installing)
            .accessibilityElement(children: .combine).accessibilityAddTraits(chosen ? [.isSelected, .isButton] : .isButton)
            if !skill.findings.isEmpty {
                VStack(alignment: .leading, spacing: 8) { ForEach(skill.findings) { LibraryFindingCard(finding: $0) } }.padding(.leading, 48)
            }
            if blocked {
                HStack(alignment: .center, spacing: 10) {
                    if forced {
                        Label("You chose to install it anyway. It stays at the checked version.", systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(AppColor.caution).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Left out unless you say otherwise.").font(.callout).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("Install anyway…") { model.ask(.installAnyway([skill.name])) }.disabled(installing)
                    }
                }
                .padding(.leading, 48)
            }
        }
        .appleCard(padding: 14, selected: chosen && can)
    }

    private func mark(_ blocked: Bool) -> (symbol: String, colour: Color) {
        if blocked { return ("exclamationmark.shield.fill", AppColor.clay) }
        if !skill.audited { return ("questionmark", AppColor.sand) }
        return ("checkmark.shield.fill", skill.findings.isEmpty ? AppColor.sage : AppColor.sand)
    }
}

/// One thing the security check found: how serious, what, where, and the line itself.
private struct LibraryFindingCard: View {
    let finding: HerdrInstallInspection.Finding

    private var serious: Bool { ["critical", "high"].contains((finding.severity ?? "").lowercased()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                FactChip(text: HerdrLibraryCopy.severity(finding.severity), symbol: serious ? "exclamationmark.octagon.fill" : nil, colour: serious ? Color.red : AppColor.caution)
                Text(finding.message ?? finding.pattern ?? "").font(.callout.weight(.medium)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if let place = finding.place { Label(place, systemImage: "doc.text").font(.caption).foregroundStyle(.secondary) }
            if let snippet = finding.snippet, !snippet.isEmpty {
                Text(snippet).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(9).background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .padding(11).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

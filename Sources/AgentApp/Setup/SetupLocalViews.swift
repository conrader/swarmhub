import SwiftUI

/// Connect on a Mac where nothing runs yet: what setting it up installs and where, in the order it happens, then
/// one button (in the window's footer). While it works the card says what it is doing; when it stops, why.
struct SetupLocalOffer: View {
    let setup: HerdrLocalSetup
    /// Setting up also answers what an AI asks the first time; the person can say no to that part.
    @Binding var answers: Bool
    /// The usual port led somewhere else and another was taken: said in one line, so the port is no surprise later.
    var portNote: String? = nil

    var body: some View {
        switch setup {
        case .offer(let hasCore):
            VStack(alignment: .leading, spacing: 12) {
                Text(WizardCopy.setUpTitle).font(.headline).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 11) {
                    item("gearshape.2.fill", AppColor.sky, WizardCopy.serviceItem, WizardCopy.serviceDetail)
                    item("terminal.fill", AppColor.sage, WizardCopy.coreItem, hasCore ? WizardCopy.coreThere : WizardCopy.coreDetail, done: hasCore)
                    item("folder.fill", AppColor.clay, WizardCopy.folderItem, WizardCopy.folderDetail)
                }
                Divider()
                SettingSwitch(title: WizardCopy.answersItem, detail: WizardCopy.answersDetail, symbol: "checkmark.shield.fill", colour: AppColor.plum, isOn: $answers)
                if let portNote { Text(portNote).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Text(WizardCopy.setUpNote).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.appleCard(padding: 14)
        case .working(let step):
            switch step {
            case .fetching(let download):
                if let download {
                    StatusCard(kind: .info, title: WizardCopy.fetching) {
                        ProgressView(value: Double(download.received), total: Double(download.total)) {
                            Text(download.attempt > 1 ? "Attempt \(download.attempt) of 3" : "SwarmHub service")
                        } currentValueLabel: {
                            Text("\(download.received.formatted()) of \(download.total.formatted()) bytes")
                                .monospacedDigit()
                        }
                    }
                } else {
                    StatusCard(kind: .working, title: "Checking the SwarmHub service release…", detail: WizardCopy.fetchingDetail)
                }
            case .installing:
                StatusCard(kind: .working, title: WizardCopy.installing, detail: WizardCopy.installingDetail)
            }
        case .failed(let line):
            StatusCard(kind: .warning, title: WizardCopy.setUpFailed, detail: line)
        }
    }

    /// One thing that is installed: its mark, its name and one sentence. `done`: it is here already.
    private func item(_ symbol: String, _ colour: Color, _ title: String, _ detail: String, done: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            SymbolTile(symbol: symbol, colour: colour, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.body.weight(.semibold))
                    if done { Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(AppColor.good).accessibilityHidden(true) }
                }
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.accessibilityElement(children: .combine)
    }
}

/// Connect on this Mac once it answers: each AI, and whether it can take a message. An AI that asks something the
/// first time shows its own question, what the answer allows, and a button that opens its window in Terminal.
struct SetupAIChecks: View {
    let checks: [HerdrAICheck]
    /// The AI programs the service looked for and did not find, each with what to do.
    var missing: [HerdrLocalReport.Program] = []
    let answer: (HerdrAICheck) -> Void
    let again: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(WizardCopy.aiTitle).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                if checks.contains(where: { $0.state != .checking && $0.state != .ready }) { Button(WizardCopy.aiAgain, action: again).controlSize(.small) }
            }
            ForEach(checks) { check in row(check) }
            ForEach(missing) { program in
                line(symbol: "minus.circle", colour: .secondary, title: WizardCopy.aiMissing(program.name), detail: program.how)
            }
        }
    }

    @ViewBuilder private func row(_ check: HerdrAICheck) -> some View {
        switch check.state {
        case .checking:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).frame(width: 22)
                Text(check.name).font(.body.weight(.semibold))
                Text(WizardCopy.aiChecking).font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }.padding(.horizontal, 14).padding(.vertical, 10).appleCard(padding: 0).accessibilityElement(children: .combine)
        case .ready:
            line(symbol: "checkmark.circle.fill", colour: AppColor.good, title: check.name, detail: WizardCopy.aiReady, inline: true)
        case .failed(let why):
            line(symbol: "exclamationmark.triangle.fill", colour: AppColor.caution, title: "\(check.name): \(WizardCopy.aiFailed)", detail: why)
        case .asks(let screen, _):
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "questionmark.bubble.fill").font(.system(size: 18)).foregroundStyle(AppColor.caution).frame(width: 22).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(check.name): \(WizardCopy.aiAsks)").font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        Text(check.note ?? WizardCopy.aiAsksDetail(check.name)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                if !screen.isEmpty {
                    Text(screen).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(12)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityLabel(screen)
                }
                HStack(spacing: 10) {
                    Button(WizardCopy.aiAnswer) { answer(check) }.buttonStyle(.appleProminent)
                    if check.note != nil { Text(WizardCopy.aiAsksDetail(check.name)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColor.clay.opacity(0.14), in: RoundedRectangle(cornerRadius: AppleMetrics.corner, style: .continuous))
        }
    }

    /// One AI on one line (`inline`), or with a sentence beneath its name.
    private func line(symbol: String, colour: Color, title: String, detail: String, inline: Bool = false) -> some View {
        HStack(alignment: inline ? .center : .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(colour).frame(width: 22).accessibilityHidden(true)
            if inline {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 14).padding(.vertical, 10).appleCard(padding: 0).accessibilityElement(children: .combine)
    }
}

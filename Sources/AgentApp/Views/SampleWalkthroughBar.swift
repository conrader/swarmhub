import SwiftUI

struct SampleWalkthroughBar: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot

    var body: some View {
        HStack {
            if let position = bot.sampleWalkthrough {
                Text("Step \(position.step.rawValue) of 3").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(position.story.button(at: position.step)) { store.advanceSampleStory(in: bot, from: position) }
                    .controlSize(.small)
            }
        }.frame(maxWidth: 720, alignment: .leading).padding(.horizontal, 16)
    }
}

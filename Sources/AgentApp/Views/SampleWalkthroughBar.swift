import SwiftUI

struct SampleWalkthroughBar: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let position = bot.sampleWalkthrough, position.step == .result,
               (position.story == .checks || position.story == .team), let review = bot.pendingSampleReview {
                SampleReviewCard(bot: bot, review: review).inspectorCard(padding: 8)
            }
            HStack {
                Menu {
                    ForEach(SampleWalkthrough.allCases, id: \.self) { story in
                        Button(story.title) { store.showSampleStory(story) }
                    }
                    Button("Inbox & approvals") { store.showOnlyAttention = true }
                } label: {
                    Text(bot.sampleWalkthrough?.story.title ?? "Walkthroughs")
                }.fixedSize().controlSize(.small).help("Choose a sample walkthrough")
                if let position = bot.sampleWalkthrough {
                    Text("Step \(position.step.rawValue) of 3").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(position.story.button(at: position.step)) { store.advanceSampleStory(in: bot, from: position) }
                        .controlSize(.small)
                }
            }
        }.frame(maxWidth: 720, alignment: .leading).padding(.horizontal, 16)
    }
}

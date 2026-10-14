import Foundation
import Testing
@testable import AgentApp

/// Motion permissions over context × preference × activity × hover × Reduce Motion.
@Suite struct AvatarMotionTests {
    static let contexts: [AvatarMotionContext] = [.list, .focus, .showcase]

    /// The rule written out independently of `AvatarMotion.resolve`.
    private func expected(_ context: AvatarMotionContext, _ preference: AvatarMotionPreference, working: Bool, hovered: Bool, reduce: Bool) -> AvatarMotionMode {
        if reduce || preference == .off { return .still }
        if working { return .working }
        if hovered && preference != .calm { return .hovered }
        return .idle
    }

    @Test func fullTruthTable() {
        var cases = 0
        for context in Self.contexts {
            for preference in AvatarMotionPreference.allCases {
                for working in [false, true] {
                    for hovered in [false, true] {
                        for reduce in [false, true] {
                            let mode = AvatarMotion.resolve(context: context, isWorking: working, isHovered: hovered, reduceMotion: reduce, preference: preference)
                            #expect(mode == expected(context, preference, working: working, hovered: hovered, reduce: reduce), "\(context) \(preference) w\(working) h\(hovered) rm\(reduce)")
                            cases += 1
                        }
                    }
                }
            }
        }
        #expect(cases == 72)
    }

    @Test func offAndReduceMotionAreAlwaysStill() {
        for context in Self.contexts {
            for working in [false, true] {
                #expect(AvatarMotion.resolve(context: context, isWorking: working, isHovered: true, reduceMotion: false, preference: .off) == .still)
                for preference in AvatarMotionPreference.allCases {
                    #expect(AvatarMotion.resolve(context: context, isWorking: working, isHovered: true, reduceMotion: true, preference: preference) == .still)
                }
            }
        }
    }

    @Test func calmAndDefaultIdleWithoutHoverInEveryLiveContext() {
        for context in [AvatarMotionContext.focus, .showcase] {
            for working in [false, true] {
                for hovered in [false, true] {
                    #expect(AvatarMotion.resolve(context: context, isWorking: working, isHovered: hovered, reduceMotion: false, preference: .calm)
                            == (working ? .working : .idle))
                }
            }
        }
        #expect(AvatarMotion.resolve(context: .focus, isWorking: false, isHovered: false, reduceMotion: false, preference: .byContext) == .idle)
        #expect(AvatarMotion.resolve(context: .list, isWorking: false, isHovered: false, reduceMotion: false, preference: .byContext) == .idle)
    }

    @Test func stillContextNeverMoves() {
        #expect(AvatarMotion.resolve(context: .still, isWorking: true, isHovered: true, reduceMotion: false, preference: .byContext) == .still)
    }

    @Test func approvalWorkAndCompletionTakePriorityOverHover() {
        for context in Self.contexts {
            #expect(AvatarMotion.resolve(context: context, isWorking: true, isHovered: true, reduceMotion: false,
                                         preference: .byContext, isWaiting: true, isCelebrating: true) == .waiting)
            #expect(AvatarMotion.resolve(context: context, isWorking: true, isHovered: true, reduceMotion: false,
                                         preference: .byContext, isCelebrating: true) == .working)
            #expect(AvatarMotion.resolve(context: context, isWorking: false, isHovered: true, reduceMotion: false,
                                         preference: .byContext, isCelebrating: true) == .celebrating)
            for preference in AvatarMotionPreference.allCases {
                #expect(AvatarMotion.resolve(context: context, isWorking: true, isHovered: true, reduceMotion: true,
                                             preference: preference, isWaiting: true, isCelebrating: true) == .still)
            }
            #expect(AvatarMotion.resolve(context: context, isWorking: true, isHovered: true, reduceMotion: false,
                                         preference: .off, isWaiting: true, isCelebrating: true) == .still)
            #expect(AvatarMotion.resolve(context: context, isWorking: false, isHovered: true, reduceMotion: false,
                                         preference: .calm, isCelebrating: true) == .idle)
        }
    }

    @Test @MainActor func preferencePersistsAndDefaultsToByContext() {
        let defaults = isolatedDefaults()
        let settings = AvatarMotionSettings(defaults: defaults)
        #expect(settings.preference == .byContext && settings.effective == .byContext)
        settings.preference = .off
        #expect(AvatarMotionSettings(defaults: defaults).preference == .off)
        settings.probeOverride = .calm
        #expect(settings.effective == .calm && defaults.string(forKey: AvatarMotionSettings.key) == "off")
    }

    @Test @MainActor func isWorkingFollowsStoreStateAndGroupMembership() {
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let a = Bot(name: "A"), b = Bot(name: "B")
        let group = GroupChat(name: "G", memberIDs: [a.id, b.id]), other = GroupChat(name: "H", memberIDs: [a.id])
        #expect(!store.isWorking(a))
        store.isStreaming = true; store.streamingBotID = a.id; store.streamingConversation = group
        #expect(store.isWorking(a) && !store.isWorking(b))
        #expect(store.isWorking(a, in: group) && !store.isWorking(a, in: other) && !store.isWorking(b, in: group))
        store.streamingConversation = a
        #expect(store.isWorking(a) && !store.isWorking(a, in: group))
        store.isStreaming = false
        #expect(!store.isWorking(a))
    }
}

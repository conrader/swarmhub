import Foundation

/// One `agentapp-bot-bundle/v1` bundle as `build_bundle` writes it: the 21 top-level keys of the golden bundles, nulls
/// written as `null` (never omitted). Built in memory by `GrokBundleBuilder`; imported through `GrokBotBundle(v1)`.
struct GrokBundleV1: Sendable, Equatable, Encodable {
    struct Message: Sendable, Equatable {
        var id: String; var seq: Int64; var timestamp: String?; var replyTo: String?
        var attachments: [Attachment]; var hidden: Bool; var channel: String; var to: String?
        var role: String; var author: String?; var text: String
    }
    struct Attachment: Sendable, Equatable { var file: String; var available: Bool }
    struct Event: Sendable, Equatable {
        var id: String; var seq: Int64
        /// The entry's `timestampMs` exactly as cached (the script copies it without a type check).
        var timestampMs: JSONValue
        var from: String; var to: String
    }
    struct Member: Sendable, Equatable { var sourceID: String; var name: String; var profile: String? }
    struct Source: Sendable, Equatable {
        var createdAtMs: Int64?; var harness: String?; var notifyOnAgentUpdates: Bool?; var hiddenFromSidebar: Bool
    }
    struct Statistics: Sendable, Equatable {
        var transcriptRows = 0, messages = 0, events = 0, toolEntriesDropped = 0, eventsDropped = 0, cardsDropped = 0
        var hiddenMessages = 0
        /// Not part of the bundle: what was left out, per kind and card or event type (`send-message/secret-request`).
        var droppedByKind: [String: Int] = [:]
    }

    static let format = "agentapp-bot-bundle/v1"

    var sourceID: String; var slug: String; var name: String; var description: String; var title: String
    var avatarShape: String?; var avatarColour: String?
    var profile: String?; var isGroup: Bool; var members: [Member]
    var messages: [Message]; var events: [Event]; var source: Source
    var limitations: [String]; var statistics: Statistics; var redactions: [String: Int]

    var instructions: String? { description.isEmpty ? nil : description }

    var json: JSONValue {
        let string = { (value: String?) in value.map(JSONValue.string) ?? .null }
        let messages = messages.map { message in
            JSONValue.object([
                "id": .string(message.id), "seq": .int(message.seq), "timestamp": string(message.timestamp), "thread": .null,
                "reply_to": string(message.replyTo),
                "attachments": .array(message.attachments.map { .object(["file": .string($0.file), "available": .bool($0.available)]) }),
                "hidden": .bool(message.hidden), "channel": .string(message.channel), "to": string(message.to),
                "role": .string(message.role), "author": string(message.author), "text": .string(message.text),
            ])
        }
        let events = events.map { event in
            JSONValue.object([
                "id": .string(event.id), "seq": .int(event.seq), "timestamp_ms": event.timestampMs,
                "event": .object(["type": .string("name-changed"), "from": .string(event.from), "to": .string(event.to)]),
            ])
        }
        let stats = statistics
        return .object([
            "format": .string(Self.format), "source_id": .string(sourceID), "slug": .string(slug), "name": .string(name),
            "description": .string(description), "title": .string(title),
            "avatar": .object(["shape": string(avatarShape), "colour": string(avatarColour)]),
            "instructions": string(instructions), "instructions_source": instructions == nil ? .null : .string("profile.description"),
            "profile": string(profile), "is_group": .bool(isGroup),
            "members": .array(members.map {
                .object(["source_id": .string($0.sourceID), "name": .string($0.name), "profile": string($0.profile)])
            }),
            "memory_facts": .array([]), "routines": .array([]), "skills": .array([]),
            "messages": .array(messages), "events": .array(events),
            "source": .object([
                "created_at_ms": source.createdAtMs.map(JSONValue.int) ?? .null, "harness": string(source.harness),
                "notify_on_agent_updates": source.notifyOnAgentUpdates.map(JSONValue.bool) ?? .null,
                "hidden_from_sidebar": .bool(source.hiddenFromSidebar),
            ]),
            "limitations": .array(limitations.map(JSONValue.string)),
            "statistics": .object([
                "transcript_rows": .int(Int64(stats.transcriptRows)), "messages": .int(Int64(stats.messages)),
                "events": .int(Int64(stats.events)), "tool_entries_dropped": .int(Int64(stats.toolEntriesDropped)),
                "events_dropped": .int(Int64(stats.eventsDropped)), "cards_dropped": .int(Int64(stats.cardsDropped)),
                "hidden_messages": .int(Int64(stats.hiddenMessages)),
            ]),
            "redactions": .object([
                "total": .int(Int64(redactions.values.reduce(0, +))),
                "counts": .object(redactions.mapValues { JSONValue.int(Int64($0)) }),
            ]),
        ])
    }

    func encode(to encoder: Encoder) throws { try json.encode(to: encoder) }
}

extension GrokBotBundle {
    /// The importer's view of a natively built bundle; equal to what `GrokBundleLoader` decodes from the same bundle.
    init(_ v1: GrokBundleV1) {
        self.init(
            format: GrokBundleV1.format, sourceId: v1.sourceID, slug: v1.slug, name: v1.name, description: v1.description,
            title: v1.title, avatar: .init(shape: v1.avatarShape, colour: v1.avatarColour), instructions: v1.instructions,
            profile: v1.profile, isGroup: v1.isGroup,
            members: v1.members.map { .init(sourceId: $0.sourceID, name: $0.name, profile: $0.profile) },
            messages: v1.messages.map { message in
                .init(id: message.id, seq: message.seq, role: message.role, author: message.author, text: message.text,
                      timestamp: message.timestamp, hidden: message.hidden, channel: message.channel, to: message.to,
                      attachments: message.attachments.map { .init(file: $0.file, available: $0.available) },
                      replyTo: message.replyTo, thread: nil)
            },
            events: v1.events.map { event in
                .init(id: event.id, seq: event.seq, timestampMs: event.timestampMs.intValue,
                      event: .init(type: "name-changed", from: event.from, to: event.to))
            },
            source: .init(hiddenFromSidebar: v1.source.hiddenFromSidebar, createdAtMs: v1.source.createdAtMs,
                          harness: v1.source.harness, notifyOnAgentUpdates: v1.source.notifyOnAgentUpdates),
            limitations: v1.limitations,
            statistics: .init(transcriptRows: v1.statistics.transcriptRows, messages: v1.statistics.messages,
                              events: v1.statistics.events, toolEntriesDropped: v1.statistics.toolEntriesDropped,
                              eventsDropped: v1.statistics.eventsDropped, cardsDropped: v1.statistics.cardsDropped,
                              hiddenMessages: v1.statistics.hiddenMessages))
    }
}

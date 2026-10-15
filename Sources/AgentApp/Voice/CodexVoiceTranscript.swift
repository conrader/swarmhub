import Foundation

/// P38 C: the live transcript. Canonical items and legacy flat transcripts are alternate representations of the same
/// speech, never two copies of a reply.
struct CodexVoiceTranscript {
    struct Entry: Identifiable, Equatable, Codable, Sendable {
        let id: String
        var role: String
        var text: String
    }
    private(set) var canonical: [Entry] = []
    private var legacy: [Entry] = []
    private var legacyActive: String?
    private var usesCanonical = false
    var entries: [Entry] { usesCanonical ? canonical : legacy }

    mutating func receive(_ method: String, params: JSONValue) {
        switch method {
        case "thread/realtime/item/started", "thread/realtime/item/completed":
            guard let item = params["item"], item["type"]?.stringValue == "transcriptSegment",
                  let id = item["id"]?.stringValue, let role = item["role"]?.stringValue else { return }
            usesCanonical = true
            Self.set(id: id, role: role, text: item["text"]?.stringValue ?? "", append: false, entries: &canonical)
        case "thread/realtime/item/transcript/delta":
            guard let id = params["itemId"]?.stringValue, let delta = params["delta"]?.stringValue,
                  let index = canonical.firstIndex(where: { $0.id == id }) else { return }
            usesCanonical = true
            canonical[index].text = String((canonical[index].text + delta).prefix(16_000))
        case "thread/realtime/transcript/delta", "thread/realtime/transcript/done":
            guard !usesCanonical, let role = params["role"]?.stringValue else { return }
            let done = method.hasSuffix("/done")
            guard let text = params[done ? "text" : "delta"]?.stringValue else { return }
            if legacy.last?.role != role { legacyActive = nil }
            let id = legacyActive ?? UUID().uuidString; legacyActive = id
            Self.set(id: id, role: role, text: text, append: !done, entries: &legacy)
            if done { legacyActive = nil }
        default: break
        }
    }

    private static func set(id: String, role: String, text: String, append: Bool, entries: inout [Entry]) {
        guard role == "user" || role == "assistant" else { return }
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].text = String(((append ? entries[index].text : "") + text).prefix(16_000))
        } else { entries.append(Entry(id: id, role: role, text: String(text.prefix(16_000)))) }
        if entries.count > 100 { entries.removeFirst(entries.count - 100) }
    }
}

/// 16-bit PCM as the realtime API sends and takes it (base64 in `data`).
struct CodexVoiceAudioChunk: Equatable, Sendable {
    let data: Data
    let sampleRate: Int
    let channels: Int
    var json: JSONValue {
        .object(["data": .string(data.base64EncodedString()), "sampleRate": .int(Int64(sampleRate)),
                 "numChannels": .int(Int64(channels)), "samplesPerChannel": .int(Int64(data.count / (2 * channels)))])
    }
    init(data: Data, sampleRate: Int = 24_000, channels: Int = 1) {
        self.data = data; self.sampleRate = sampleRate; self.channels = channels
    }
    init(json: JSONValue) throws {
        guard let encoded = json["data"]?.stringValue, encoded.utf8.count <= 2_000_000,
              let data = Data(base64Encoded: encoded), !data.isEmpty,
              let rate = json["sampleRate"]?.intValue, (8_000...96_000).contains(rate),
              let channels = json["numChannels"]?.intValue, (1...2).contains(channels),
              data.count % (2 * Int(channels)) == 0 else { throw LiveVoiceError.invalidResponse }
        self.init(data: data, sampleRate: Int(rate), channels: Int(channels))
    }
}

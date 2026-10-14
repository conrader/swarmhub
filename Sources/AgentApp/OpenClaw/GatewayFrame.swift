import Foundation

/// P12: the Gateway's three JSON text frames. Unknown fields and events are ignored; a malformed frame decodes to nil
/// and is skipped by the reader, never a crash.
enum GatewayFrame: Sendable, Equatable {
    case request(id: String, method: String, params: GatewayJSON?)
    case response(GatewayResponse)
    case event(GatewayEvent)

    static func decode(_ text: String) -> GatewayFrame? {
        guard let value = GatewayJSON.parse(text), let type = value["type"]?.string else { return nil }
        switch type {
        case "req":
            guard let id = value["id"]?.string, let method = value["method"]?.string else { return nil }
            return .request(id: id, method: method, params: value["params"])
        case "res":
            guard let id = value["id"]?.string, let ok = value["ok"]?.bool else { return nil }
            return .response(.init(id: id, ok: ok, payload: value["payload"], error: value["error"].flatMap(GatewayError.init(json:))))
        case "event":
            guard let event = value["event"]?.string else { return nil }
            return .event(.init(event: event, payload: value["payload"] ?? .null, seq: value["seq"]?.int))
        default: return nil
        }
    }

    /// `{type:"req",id,method,params}` as sent.
    static func requestText(id: String, method: String, params: GatewayJSON) -> String {
        GatewayJSON.object(["type": "req", "id": .string(id), "method": .string(method), "params": params]).jsonText
    }
}

struct GatewayResponse: Sendable, Equatable {
    let id: String; let ok: Bool; let payload: GatewayJSON?; let error: GatewayError?
}

struct GatewayEvent: Sendable, Equatable {
    let event: String; let payload: GatewayJSON; let seq: Int?
}

/// `error{code,message,details?,retryable?,retryAfterMs?}`. Callers branch on `code` and `details.code`, never `message`.
struct GatewayError: Error, Sendable, Equatable, LocalizedError {
    var code: String; var message: String; var details: Details?; var retryable = false; var retryAfterMs: Int?

    /// The `details` fields SwarmHub reads; the rest stay in `raw`.
    struct Details: Sendable, Equatable {
        var code: String?; var requestId: String?; var reason: String?; var recommendedNextStep: String?
        var retryable: Bool?; var canRetryWithDeviceToken: Bool?; var missingScope: String?; var requiredScopes: [String] = []
        var deviceId: String?; var raw: GatewayJSON = .null

        init(json: GatewayJSON) {
            code = json["code"]?.string; requestId = json["requestId"]?.string; reason = json["reason"]?.string
            recommendedNextStep = json["recommendedNextStep"]?.string; retryable = json["retryable"]?.bool
            canRetryWithDeviceToken = json["canRetryWithDeviceToken"]?.bool; missingScope = json["missingScope"]?.string
            requiredScopes = json["requiredScopes"]?.strings ?? []; deviceId = json["deviceId"]?.string; raw = json
        }
    }

    init(code: String, message: String, details: Details? = nil, retryable: Bool = false, retryAfterMs: Int? = nil) {
        self.code = code; self.message = message; self.details = details; self.retryable = retryable; self.retryAfterMs = retryAfterMs
    }

    init?(json: GatewayJSON) {
        guard let code = json["code"]?.string else { return nil }
        self.code = code; message = json["message"]?.string ?? ""
        details = json["details"].flatMap { $0.object == nil ? nil : Details(json: $0) }
        retryable = json["retryable"]?.bool ?? false; retryAfterMs = json["retryAfterMs"]?.int
    }

    /// Either code, so `NOT_PAIRED` + `PAIRING_REQUIRED` and a bare `AUTH_TOKEN_MISMATCH` both match.
    func has(_ value: String) -> Bool { code == value || details?.code == value }

    /// The method is not on this Gateway, or a parameter is newer than it (`INVALID_REQUEST`, unknown method).
    var isUnsupported: Bool { has("INVALID_REQUEST") || has("METHOD_NOT_FOUND") || has("UNKNOWN_METHOD") }

    var errorDescription: String? { message.isEmpty ? code : "\(message) (\(code))" }
}

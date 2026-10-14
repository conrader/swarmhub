import Foundation
import SwarmHubCore

/// Shared encoding keeps desktop and iOS below Hermes' per-part and body limits.
extension HermesBackend {
    static let maxTextPartScalars = HermesContent.maxTextPartScalars
    static let maxRequestBodyBytes = HermesContent.maxRequestBodyBytes
    static let requestTooLargeMessage = CoreError.requestTooLarge.localizedDescription

    static func contentParts(text: String, images: [String], limit: Int = maxTextPartScalars) -> Any {
        HermesContent.parts(text: text, images: images, limit: limit)
    }
    static func splitText(_ text: String, limit: Int = maxTextPartScalars) -> [String] {
        HermesContent.splitText(text, limit: limit)
    }
    static func requestBody(_ object: [String: Any], limit: Int = maxRequestBodyBytes) throws -> Data {
        do { return try HermesContent.body(object, limit: limit) }
        catch CoreError.requestTooLarge { throw BackendError.unavailable(requestTooLargeMessage) }
    }
}

import Foundation

/// P38 C: where SwarmHub keeps the deAPI dictation key: main's key vault (the v2 Keychain item, read silently). The
/// account name is the old line's, so a key saved there is found under the legacy service and copied to v2.
enum DeAPICredentials {
    static let account = "deapi.dictation"
}

enum DeAPIError: LocalizedError, Equatable {
    case missingKey, invalidResponse, noModel, invalidAudio, noSpeech, jobFailed, timedOut
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .missingKey: "Dictation is not set up: add your deAPI API key in \(SettingsLayout.path(.voice))."
        case .invalidResponse: "deAPI returned an unreadable transcription response. Please try again."
        case .noModel: "No audio transcription model is available for your deAPI account."
        case .invalidAudio: "The recording is empty or exceeds deAPI’s 20 MB audio limit."
        case .noSpeech: "No speech was detected. Try recording again."
        case .jobFailed: "deAPI could not transcribe this recording. Please try again."
        case .timedOut: "deAPI took too long to transcribe. Please try again."
        case .http(401), .http(403): "deAPI rejected the API key. Check your key and account in \(SettingsLayout.path(.voice))."
        case .http(402): "Your deAPI account needs credit to transcribe audio."
        case .http(429): "deAPI’s request limit was reached. Please try again later."
        case .http(422): "deAPI could not accept this recording or model. Please try again."
        case .http: "deAPI is unavailable. Please try again later."
        }
    }
}

/// Reject redirects on authenticated API calls; signed result URLs are fetched without the API key.
private final class DeAPIHTTPDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// deAPI's native v2 transcription: pick a speech-to-text model, upload the WAV, poll the job.
struct DeAPIClient: Sendable {
    private struct Models: Decodable {
        let data: [Model]
        let meta: Meta
        struct Meta: Decodable { let last_page: Int }
        struct Model: Decodable { let slug: String; let inference_types: [String] }
    }
    private struct Submission: Decodable {
        let data: JobID
        struct JobID: Decodable { let request_id: String }
    }
    private struct Job: Decodable {
        let data: Result
        struct Result: Decodable { let status: String; let result: String?; let result_url: String? }
    }

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config, delegate: DeAPIHTTPDelegate(), delegateQueue: nil)
    }()
    let apiKey: String
    var session: URLSession = Self.session
    var baseURL = URL(string: "https://api.deapi.ai/api/v2/")!
    var pollInterval: Duration = .seconds(2)
    var pollTimeout: Duration = .seconds(180)
    /// testspeed: the wait between polls is injected.
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    private var token: String {
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // The dpn-sk- prefix belongs to deAPI's OpenAI gateway; native v2 uses the raw token.
        return value.hasPrefix("dpn-sk-") ? String(value.dropFirst(7)) : value
    }

    func transcriptionModel() async throws -> String {
        var candidates: [String] = []
        for page in 1...20 {
            try Task.checkCancellation()
            let data = try await fetch("models?limit=50&page=\(page)")
            let models = try decode(Models.self, data)
            candidates += models.data.filter {
                !$0.slug.isEmpty && $0.inference_types.contains { ["audio_file2text", "audio2text", "aud2txt", "audio-to-text", "transcription"].contains($0) }
            }.map(\.slug)
            guard models.meta.last_page >= page, models.meta.last_page <= 20 else { throw DeAPIError.invalidResponse }
            if page == models.meta.last_page {
                guard let model = candidates.first(where: { $0.localizedCaseInsensitiveContains("whisper") }) ?? candidates.first else { throw DeAPIError.noModel }
                return model
            }
        }
        throw DeAPIError.invalidResponse
    }

    func transcribe(file: URL) async throws -> String {
        guard !token.isEmpty else { throw DeAPIError.missingKey }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 44, size <= 20_000_000 else { throw DeAPIError.invalidAudio }
        let model = try await transcriptionModel()
        try Task.checkCancellation()
        let audio = try Data(contentsOf: file)
        let boundary = "SwarmHub-\(UUID().uuidString)"
        let body = Self.multipart(audio: audio, model: model, boundary: boundary)
        let submitted = try decode(Submission.self, await fetch("audio/transcriptions", body: body, contentType: "multipart/form-data; boundary=\(boundary)"))
        let id = submitted.data.request_id
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { throw DeAPIError.invalidResponse }
        let deadline = ContinuousClock.now.advanced(by: pollTimeout)
        while true {
            try Task.checkCancellation()
            let job = try decode(Job.self, await fetch("jobs/\(id)"))
            switch job.data.status {
            case "done":
                if let urlString = job.data.result_url {
                    guard let url = URL(string: urlString), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { throw DeAPIError.invalidResponse }
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 30
                    let data = try await response(request)
                    guard let text = String(data: data, encoding: .utf8) else { throw DeAPIError.invalidResponse }
                    return try Self.transcript(text)
                }
                return try Self.transcript(job.data.result ?? "")
            case "error", "failed": throw DeAPIError.jobFailed
            case "pending", "processing": break
            default: throw DeAPIError.invalidResponse
            }
            guard ContinuousClock.now < deadline else { throw DeAPIError.timedOut }
            try await sleep(min(pollInterval, ContinuousClock.now.duration(to: deadline)))
        }
    }

    private func fetch(_ path: String, body: Data? = nil, contentType: String? = nil) async throws -> Data {
        guard !token.isEmpty else { throw DeAPIError.missingKey }
        var request = URLRequest(url: URL(string: path, relativeTo: baseURL)!.absoluteURL)
        request.timeoutInterval = 30
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SwarmHub/voice-dictation", forHTTPHeaderField: "User-Agent")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        return try await response(request)
    }

    private func response(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw DeAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw DeAPIError.http(http.statusCode) }
        guard data.count <= 2_000_000 else { throw DeAPIError.invalidResponse }
        return data
    }
    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw DeAPIError.invalidResponse }
    }
    static func multipart(audio: Data, model: String, boundary: String) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("include_ts", "0")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"source_file\"; filename=\"dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
    private static func transcript(_ value: String) throws -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DeAPIError.noSpeech }
        return text
    }
}

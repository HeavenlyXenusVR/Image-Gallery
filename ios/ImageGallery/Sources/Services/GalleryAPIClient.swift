import Foundation

enum GalleryAPIError: LocalizedError {
    case notConfigured
    case invalidURL
    case http(status: Int, message: String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No backend configured yet. Set the backend URL in Settings."
        case .invalidURL:
            return "Invalid request URL."
        case .http(_, let message):
            return message
        case .decoding(let message):
            return "Could not read the server's response: \(message)"
        }
    }
}

/// Async/await networking client for the Lua backend. Mirrors the request
/// shape `frontend/src/api.js`'s `apiFetch` already uses today (Bearer token
/// header, `/api/...` paths, `{"detail": "..."}` error bodies) so the backend
/// itself needs zero changes to support this client.
final class GalleryAPIClient {
    static let shared = GalleryAPIClient()

    private static let tokenKeychainKey = "session_token"

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        // The backend is reached through a rotating tunnel URL (see
        // LiveConfigService) rather than a stable domain, so brief connectivity
        // blips (Wi-Fi/cellular handoff, tunnel recycling) are routine, not
        // exceptional. `waitsForConnectivity` lets URLSession itself absorb
        // those instead of failing the request immediately with "the network
        // connection was lost" — the same class of error `sendWithRetry` below
        // also retries at the app level once the tunnel URL has actually
        // rotated out from under us. `timeoutIntervalForResource` is left at
        // its (very generous) default rather than shortened: unlike
        // `timeoutIntervalForRequest` (an idle timeout, reset by activity),
        // it's a hard ceiling on the whole request — and multi-GB video
        // uploads legitimately run for minutes.
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration)

        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    // MARK: Token

    var authToken: String? {
        get { KeychainHelper.get(forKey: Self.tokenKeychainKey) }
        set {
            if let newValue {
                KeychainHelper.set(newValue, forKey: Self.tokenKeychainKey)
            } else {
                KeychainHelper.remove(forKey: Self.tokenKeychainKey)
            }
        }
    }

    var isAuthenticated: Bool { authToken != nil }

    // MARK: Request building

    private func makeURL(path: String, query: [String: String]?) throws -> URL {
        let origin = LiveConfigService.shared.currentOrigin
        guard !origin.isEmpty else { throw GalleryAPIError.notConfigured }
        guard var components = URLComponents(string: origin + path) else { throw GalleryAPIError.invalidURL }
        if let query, !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw GalleryAPIError.invalidURL }
        return url
    }

    /// `requiresAuth` documents intent at the call site (most endpoints work for
    /// anonymous viewers but personalize their response when a token is present,
    /// same as the web app's `_auth_optional`) — the token is attached whenever
    /// one exists either way, since sending it to a public/optional-auth
    /// endpoint is harmless and the backend ignores it if not applicable.
    private func baseRequest(path: String, method: String, query: [String: String]?, requiresAuth: Bool) throws -> URLRequest {
        var request = URLRequest(url: try makeURL(path: path, query: query))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Errors that mean the request likely never reached the server at all
    /// (dropped connection, tunnel mid-rotation, DNS blip) rather than the
    /// server having received and acted on it — safe to retry after
    /// refreshing the backend origin, unlike an HTTP error status.
    private static func isTransientNetworkError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .networkConnectionLost, .timedOut, .notConnectedToInternet,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    /// Mirrors `frontend/src/api.js`'s `fetchWithRemoteRetry`: the backend sits
    /// behind a tunnel URL that rotates independently of the app, so a
    /// transient network error is re-tried against a freshly-fetched origin
    /// (up to twice, with a short backoff) before surfacing to the caller —
    /// otherwise every tunnel rotation reads as a random "network was lost"
    /// failure until the user manually hits Refresh in Settings.
    private func sendWithRetry<T>(
        buildRequest: () throws -> URLRequest,
        perform: (URLRequest) async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await perform(try buildRequest())
            } catch {
                guard Self.isTransientNetworkError(error), attempt < 2 else { throw error }
                attempt += 1
                await LiveConfigService.shared.refresh()
                try? await Task.sleep(nanoseconds: UInt64(300_000_000 * attempt))
            }
        }
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200...299).contains(http.statusCode) else { return }
        let message = (try? decoder.decode(ErrorPayload.self, from: data))?.detailMessage
            ?? String(data: data, encoding: .utf8)
            ?? "Request failed (\(http.statusCode))."
        throw GalleryAPIError.http(status: http.statusCode, message: message)
    }

    // Bounds every "should be fast" request (JSON GET/POST, void acks, small
    // downloads) against the same waitsForConnectivity hang Timeout.swift
    // documents for SessionStore -- previously only bootstrap()/
    // refreshCurrentUser() were wrapped, so every OTHER screen (profile,
    // feeds, HLS playlist fetches, ...) stayed exposed to a request made at
    // an instant the network is genuinely unreachable just sitting forever
    // with isLoading stuck true and no error ever surfacing -- reported as
    // "nothing in profile loads at all". Deliberately NOT applied to
    // upload/uploadChunkBytes, which need to tolerate multi-minute transfers
    // by design.
    private static let requestTimeoutSeconds: TimeInterval = 25

    private func withRequestTimeout<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        do {
            return try await withTimeout(seconds: Self.requestTimeoutSeconds, operation: operation)
        } catch is TimedOutError {
            throw GalleryAPIError.http(status: 0, message: "The request timed out. Check your connection and try again.")
        }
    }

    // MARK: No-body requests (GET/DELETE/POST-with-no-payload)

    @discardableResult
    func requestJSON<T: Decodable>(_ path: String, method: String = "GET", query: [String: String]? = nil, requiresAuth: Bool = true) async throws -> T {
        let (data, response) = try await withRequestTimeout {
            try await self.sendWithRetry(
                buildRequest: { try self.baseRequest(path: path, method: method, query: query, requiresAuth: requiresAuth) },
                perform: { try await self.session.data(for: $0) }
            )
        }
        try validate(response, data: data)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw GalleryAPIError.decoding(String(describing: error))
        }
    }

    // MARK: JSON-body requests

    @discardableResult
    func requestJSON<T: Decodable, B: Encodable>(_ path: String, method: String = "POST", body: B, query: [String: String]? = nil, requiresAuth: Bool = true) async throws -> T {
        // Encoded to Data up front, outside the @Sendable timeout-race
        // closure below -- B itself isn't guaranteed Sendable, but the
        // encoded bytes are.
        let bodyData = try encoder.encode(body)
        let (data, response) = try await withRequestTimeout {
            try await self.sendWithRetry(
                buildRequest: {
                    var request = try self.baseRequest(path: path, method: method, query: query, requiresAuth: requiresAuth)
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = bodyData
                    return request
                },
                perform: { try await self.session.data(for: $0) }
            )
        }
        try validate(response, data: data)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw GalleryAPIError.decoding(String(describing: error))
        }
    }

    // MARK: Multipart uploads (media upload, analyze, avatar)

    enum MultipartFileSource {
        case data(Data)
        /// A file already on disk (e.g. a picked video copied there without
        /// ever loading it into memory) — streamed straight into the request
        /// body file instead of being read into a `Data` all at once, so a
        /// multi-GB upload doesn't hold the whole thing in RAM.
        case fileURL(URL)
    }

    struct MultipartFile {
        var fieldName: String
        var fileName: String
        var mimeType: String
        var source: MultipartFileSource
    }

    private func multipartFieldsData(_ fields: [String: String], boundary: String) -> Data {
        var data = Data()
        for (key, value) in fields {
            data.append("--\(boundary)\r\n".data(using: .utf8)!)
            data.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
            data.append("\(value)\r\n".data(using: .utf8)!)
        }
        return data
    }

    private func multipartFileHeaderData(_ file: MultipartFile, boundary: String) -> Data {
        var data = Data()
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"\(file.fieldName)\"; filename=\"\(file.fileName)\"\r\n".data(using: .utf8)!)
        data.append("Content-Type: \(file.mimeType)\r\n\r\n".data(using: .utf8)!)
        return data
    }

    @discardableResult
    func upload<T: Decodable>(_ path: String, fields: [String: String], file: MultipartFile, requiresAuth: Bool = true) async throws -> T {
        let boundary = "ImageGallery-\(UUID().uuidString)"
        // The multipart body (in-memory or on-disk) is assembled once, up front —
        // it doesn't depend on the backend origin, so `sendWithRetry` below can
        // reuse it across attempts instead of re-composing (or, for a picked
        // video, re-reading a multi-GB file from disk) on every retry.
        let bodySource: MultipartFileSource
        switch file.source {
        case .data(let fileData):
            var body = multipartFieldsData(fields, boundary: boundary)
            body.append(multipartFileHeaderData(file, boundary: boundary))
            body.append(fileData)
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
            bodySource = .data(body)

        case .fileURL(let fileURL):
            // Compose the multipart envelope in a temp file on disk — reading
            // the picked file in small chunks instead of loading it whole —
            // so a multi-GB upload is never fully buffered in RAM either here
            // or by URLSession while it streams the request body over the
            // network.
            let bodyURL = FileManager.default.temporaryDirectory.appendingPathComponent("upload-body-\(UUID().uuidString)")
            do {
                FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
                let writer = try FileHandle(forWritingTo: bodyURL)
                var head = multipartFieldsData(fields, boundary: boundary)
                head.append(multipartFileHeaderData(file, boundary: boundary))
                try writer.write(contentsOf: head)
                let reader = try FileHandle(forReadingFrom: fileURL)
                while let chunk = try reader.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
                    try writer.write(contentsOf: chunk)
                }
                try reader.close()
                try writer.write(contentsOf: "\r\n--\(boundary)--\r\n".data(using: .utf8)!)
                try writer.close()
            } catch {
                try? FileManager.default.removeItem(at: bodyURL)
                throw GalleryAPIError.http(status: 0, message: "Could not prepare the upload: \(error.localizedDescription)")
            }
            bodySource = .fileURL(bodyURL)
        }
        defer {
            if case .fileURL(let bodyURL) = bodySource {
                try? FileManager.default.removeItem(at: bodyURL)
            }
        }

        let (data, response) = try await sendWithRetry(
            buildRequest: {
                var request = try baseRequest(path: path, method: "POST", query: nil, requiresAuth: requiresAuth)
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                return request
            },
            perform: { request in
                switch bodySource {
                case .data(let body):
                    // `httpBody` is intentionally left unset here — `session.upload(for:from:)`
                    // takes the body as its own `from:` argument, so setting both would
                    // just duplicate the payload in memory for no benefit.
                    return try await self.session.upload(for: request, from: body)
                case .fileURL(let bodyURL):
                    return try await self.session.upload(for: request, fromFile: bodyURL)
                }
            }
        )

        try validate(response, data: data)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw GalleryAPIError.decoding(String(describing: error))
        }
    }

    /// Posts a single raw chunk (no multipart envelope) for the chunked
    /// upload flow -- see `uploadMediaChunked` in +Endpoints.swift. Returns
    /// the decoded JSON ack (`{"ok": true, "received_bytes": ...}`).
    @discardableResult
    func uploadChunkBytes<T: Decodable>(_ path: String, query: [String: String], data: Data) async throws -> T {
        let (respData, response) = try await sendWithRetry(
            buildRequest: {
                var request = try baseRequest(path: path, method: "POST", query: query, requiresAuth: true)
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                return request
            },
            perform: { request in try await self.session.upload(for: request, from: data) }
        )
        try validate(response, data: respData)
        do {
            return try decoder.decode(T.self, from: respData)
        } catch {
            throw GalleryAPIError.decoding(String(describing: error))
        }
    }

    /// Fire-and-forget-shaped DELETE/POST calls that only return `{"ok": true}`-style acks.
    func requestVoid(_ path: String, method: String, query: [String: String]? = nil, requiresAuth: Bool = true) async throws {
        let (data, response) = try await withRequestTimeout {
            try await self.sendWithRetry(
                buildRequest: { try self.baseRequest(path: path, method: method, query: query, requiresAuth: requiresAuth) },
                perform: { try await self.session.data(for: $0) }
            )
        }
        try validate(response, data: data)
    }

    /// Downloads a raw file (e.g. the "download my data" JSON export).
    func download(_ path: String, requiresAuth: Bool = true) async throws -> Data {
        let (data, response) = try await withRequestTimeout {
            try await self.sendWithRetry(
                buildRequest: { try self.baseRequest(path: path, method: "GET", query: nil, requiresAuth: requiresAuth) },
                perform: { try await self.session.data(for: $0) }
            )
        }
        try validate(response, data: data)
        return data
    }

    /// POST-with-JSON-body variant of `download` (e.g. the batch zip
    /// download, which needs to send the selected media ids) -- same
    /// request-building as `requestJSON`'s POST overload, just returning the
    /// raw response bytes instead of decoding JSON.
    func downloadPOST<B: Encodable>(_ path: String, body: B, requiresAuth: Bool = true) async throws -> Data {
        let bodyData = try encoder.encode(body)
        let (data, response) = try await withRequestTimeout {
            try await self.sendWithRetry(
                buildRequest: {
                    var request = try self.baseRequest(path: path, method: "POST", query: nil, requiresAuth: requiresAuth)
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = bodyData
                    return request
                },
                perform: { try await self.session.data(for: $0) }
            )
        }
        try validate(response, data: data)
        return data
    }
}

private struct ErrorPayload: Decodable {
    let detail: DetailValue?

    var detailMessage: String? {
        switch detail {
        case .text(let value): return value
        case .list(let values): return values.joined(separator: "; ")
        case .none: return nil
        }
    }

    enum DetailValue: Decodable {
        case text(String)
        case list([String])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                self = .text(value)
                return
            }
            if let values = try? container.decode([DetailItem].self) {
                self = .list(values.map(\.message))
                return
            }
            self = .text("Request failed.")
        }
    }

    struct DetailItem: Decodable {
        let msg: String?
        var message: String { msg ?? "Request failed." }
    }
}

struct EmptyBody: Encodable {}

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

/// Async/await networking client for the FastAPI backend. Mirrors the request
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

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200...299).contains(http.statusCode) else { return }
        let message = (try? decoder.decode(ErrorPayload.self, from: data))?.detailMessage
            ?? String(data: data, encoding: .utf8)
            ?? "Request failed (\(http.statusCode))."
        throw GalleryAPIError.http(status: http.statusCode, message: message)
    }

    // MARK: No-body requests (GET/DELETE/POST-with-no-payload)

    @discardableResult
    func requestJSON<T: Decodable>(_ path: String, method: String = "GET", query: [String: String]? = nil, requiresAuth: Bool = true) async throws -> T {
        let request = try baseRequest(path: path, method: method, query: query, requiresAuth: requiresAuth)
        let (data, response) = try await session.data(for: request)
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
        var request = try baseRequest(path: path, method: method, query: query, requiresAuth: requiresAuth)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw GalleryAPIError.decoding(String(describing: error))
        }
    }

    // MARK: Multipart uploads (media upload, analyze, avatar)

    struct MultipartFile {
        var fieldName: String
        var fileName: String
        var mimeType: String
        var data: Data
    }

    @discardableResult
    func upload<T: Decodable>(_ path: String, fields: [String: String], file: MultipartFile, requiresAuth: Bool = true) async throws -> T {
        var request = try baseRequest(path: path, method: "POST", query: nil, requiresAuth: requiresAuth)
        let boundary = "ImageGallery-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        for (key, value) in fields {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(file.fieldName)\"; filename=\"\(file.fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(file.mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(file.data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        // `httpBody` is intentionally left unset here — `session.upload(for:from:)`
        // takes the body as its own `from:` argument, so setting both would just
        // duplicate the payload in memory for no benefit.
        let (data, response) = try await session.upload(for: request, from: body)
        try validate(response, data: data)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw GalleryAPIError.decoding(String(describing: error))
        }
    }

    /// Fire-and-forget-shaped DELETE/POST calls that only return `{"ok": true}`-style acks.
    func requestVoid(_ path: String, method: String, query: [String: String]? = nil, requiresAuth: Bool = true) async throws {
        let request = try baseRequest(path: path, method: method, query: query, requiresAuth: requiresAuth)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
    }

    /// Downloads a raw file (e.g. the "download my data" JSON export).
    func download(_ path: String, requiresAuth: Bool = true) async throws -> Data {
        let request = try baseRequest(path: path, method: "GET", query: nil, requiresAuth: requiresAuth)
        let (data, response) = try await session.data(for: request)
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

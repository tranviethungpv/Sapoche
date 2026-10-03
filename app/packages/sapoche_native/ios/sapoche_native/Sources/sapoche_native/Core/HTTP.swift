import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct HTTPFailure: Error, LocalizedError {
    let status: Int
    let service: String

    var errorDescription: String? { "\(service) answered \(status)" }
}

struct HTTPReply {
    let status: Int
    let data: Data
    let headers: [String: String]

    var text: String { String(decoding: data, as: UTF8.self) }
}

/// Sends a request and gives back the answer; the one place the network is touched, so tests can stand in for it.
protocol HTTPClient {
    func send(_ request: URLRequest) async throws -> HTTPReply
}

struct URLSessionHTTP: HTTPClient {
    let session: URLSession

    init(timeout: TimeInterval = 30) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> HTTPReply {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let response = response as? HTTPURLResponse else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                var headers: [String: String] = [:]
                for (key, value) in response.allHeaderFields {
                    if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
                }
                continuation.resume(returning: HTTPReply(status: response.statusCode, data: data ?? Data(), headers: headers))
            }
            task.resume()
        }
    }
}

extension HTTPClient {
    /// POSTs [body] as JSON.
    func postJSON(_ url: String, body: [String: Any], headers: [String: String] = [:], service: String) async throws -> JSON {
        guard let address = URL(string: url) else { throw URLError(.badURL) }
        var request = URLRequest(url: address)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let reply = try await send(request)
        guard (200..<300).contains(reply.status) else { throw HTTPFailure(status: reply.status, service: service) }
        guard let json = JSON.parse(data: reply.data) else { throw URLError(.cannotParseResponse) }
        return json
    }
}

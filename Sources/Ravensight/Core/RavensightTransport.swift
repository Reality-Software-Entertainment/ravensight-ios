import Foundation

/// One outbound HTTP request. Deliberately free of URLSession types so the
/// batching and retry logic can be exercised with a fake transport in a plain
/// unit test.
public struct RavensightRequest: Equatable {
    public var method: String
    public var url: String
    public var headers: [String: String]
    /// Serialized JSON body, or nil for a GET.
    public var body: Data?

    public init(method: String, url: String, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// One inbound HTTP response. A transport level failure (no connection, DNS,
/// timeout) is reported as status 0 so the protocol core treats it like any
/// other retryable outcome instead of throwing into game code.
public struct RavensightResponse {
    public var status: Int
    public var body: Data?
    /// Raw Retry-After header value, or nil.
    public var retryAfter: String?

    public init(status: Int, body: Data? = nil, retryAfter: String? = nil) {
        self.status = status
        self.body = body
        self.retryAfter = retryAfter
    }

    public static func networkFailure(_ reason: String) -> RavensightResponse {
        return RavensightResponse(status: 0, body: reason.data(using: .utf8))
    }

    /// Parsed body, or nil when the body was absent or malformed.
    public var json: Any? {
        guard let body = body, !body.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: body)
    }

    /// The server's "error" field if it sent one, else the fallback.
    public func errorCode(fallback: String) -> String {
        if let object = json as? [String: Any], let error = object["error"] as? String, !error.isEmpty {
            return error
        }
        return fallback
    }

    /// Retry-After in milliseconds, or 0 when absent or not a delta seconds value.
    public var retryAfterMs: Int64 {
        return RavensightResponse.parseRetryAfterMs(retryAfter)
    }

    public static func parseRetryAfterMs(_ value: String?) -> Int64 {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return 0 }
        guard let seconds = Double(raw), seconds.isFinite, seconds >= 0 else {
            // The HTTP-date form is legal but the API sends delta seconds.
            // Fall back to the caller's own exponential backoff.
            return 0
        }
        return Int64((seconds * 1000).rounded())
    }
}

/// Sends one request and never throws. Implementations must translate every
/// failure into a RavensightResponse (status 0 for transport failures).
public protocol RavensightTransport {
    func send(_ request: RavensightRequest, completion: @escaping (RavensightResponse) -> Void)
}

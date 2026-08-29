import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The production transport: URLSession, nothing else. Translates every
/// failure into a RavensightResponse so the protocol core never sees a thrown
/// error.
public final class RavensightURLSessionTransport: RavensightTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: RavensightRequest, completion: @escaping (RavensightResponse) -> Void) {
        guard let url = URL(string: request.url) else {
            completion(.networkFailure("invalid url"))
            return
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let task = session.dataTask(with: urlRequest) { data, response, error in
            if let http = response as? HTTPURLResponse {
                completion(RavensightResponse(
                    status: http.statusCode,
                    body: data,
                    retryAfter: http.value(forHTTPHeaderField: "Retry-After")
                ))
            } else {
                completion(.networkFailure(error?.localizedDescription ?? "network error"))
            }
        }
        task.resume()
    }
}

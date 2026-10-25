import Foundation

public struct APIResponse: Sendable {
    public var status: Int
    public var data: Data
    public var contentType: String
    public var headers: [String: String]

    public init(status: Int, data: Data, contentType: String, headers: [String: String] = [:]) {
        self.status = status
        self.data = data
        self.contentType = contentType
        self.headers = headers
    }
}

public typealias Transport = (_ method: String, _ path: String, _ body: Data?) throws -> APIResponse

public enum ProxyError: Error, CustomStringConvertible {
    case unreachable(base: String)
    case badArguments(String)

    public var description: String {
        switch self {
        case .unreachable(let base):
            return "SimpleSKP is not reachable at \(base) — launch /Applications/SimpleSKP.app and retry."
        case .badArguments(let why):
            return why
        }
    }
}

public func apiBaseURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
    let port = environment["SIMPLESKP_API_PORT"].flatMap { Int($0) } ?? 17950
    return "http://127.0.0.1:\(port)"
}

public func urlSessionTransport(base: String, timeout: TimeInterval = 30) -> Transport {
    return { method, path, body in
        guard let url = URL(string: base + path) else { throw ProxyError.badArguments("bad path \(path)") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }

        let done = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable {
            var result: Result<APIResponse, Error>
            init(_ r: Result<APIResponse, Error>) { result = r }
        }
        let box = Box(.failure(ProxyError.unreachable(base: base)))
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, let data {
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields {
                    if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
                }
                box.result = .success(APIResponse(
                    status: http.statusCode,
                    data: data,
                    contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "",
                    headers: headers
                ))
            } else {
                box.result = .failure(ProxyError.unreachable(base: base))
            }
            done.signal()
        }.resume()
        done.wait()
        return try box.result.get()
    }
}

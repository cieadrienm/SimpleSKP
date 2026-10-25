import Foundation

public final class SimpleSKPMCPServer {
    let transport: Transport
    let apiBase: String
    let version: String

    public init(transport: @escaping Transport, apiBase: String = "http://127.0.0.1:17950", version: String = "1.2.0") {
        self.transport = transport
        self.apiBase = apiBase
        self.version = version
    }

    public func run() {
        while let line = readLine(strippingNewline: true) {
            if let response = handle(line: line) { Self.write(response) }
        }
    }

    static func write(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    public func handle(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let message = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
        }
        guard let method = message["method"] as? String else { return nil }
        guard let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]

        var result: [String: Any]?
        var failure: (code: Int, message: String)?

        switch method {
        case "initialize":
            result = [
                "protocolVersion": params["protocolVersion"] as? String ?? "2024-11-05",
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "simpleskp", "version": version],
                "instructions": "Controls SimpleSKP, the native macOS 3D viewer for SketchUp (.skp) files (cie Adrien M). Call simpleskp_state first; open models with simpleskp_open; control the 3D camera (position, target, yaw, pitch, FOV, focal length mm, exposure, standard views) with simpleskp_camera; switch scenes and layers with simpleskp_scene and simpleskp_layers; adjust PBR/Clay/X-Ray shading, sun/point lights, SSAO, and backdrop with simpleskp_rendering; inspect the 3D viewport visually with simpleskp_snapshot.",
            ]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": simpleSKPToolDefinitions]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            guard simpleSKPToolDefinitions.contains(where: { $0["name"] as? String == name }) else {
                failure = (-32602, "unknown tool: \(name)")
                break
            }
            do {
                result = try callTool(name, params["arguments"] as? [String: Any] ?? [:])
            } catch {
                result = ["content": [["type": "text", "text": "\(error)"]], "isError": true]
            }
        default:
            failure = (-32601, "method not found: \(method)")
        }

        if let result { return encode(["jsonrpc": "2.0", "id": id, "result": result]) }
        let f = failure ?? (-32601, "method not found: \(method)")
        return encode(["jsonrpc": "2.0", "id": id, "error": ["code": f.code, "message": f.message]])
    }

    func encode(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func textResult(_ response: APIResponse) -> [String: Any] {
        ["content": [["type": "text", "text": String(decoding: response.data, as: UTF8.self)]], "isError": response.status >= 400]
    }

    func imageResult(_ response: APIResponse, caption: String) -> [String: Any] {
        guard response.status == 200, !response.contentType.lowercased().contains("json") else { return textResult(response) }
        let mime = response.contentType.lowercased().hasPrefix("image/") ? String(response.contentType.split(separator: ";")[0]) : "image/png"
        return [
            "content": [
                ["type": "image", "data": response.data.base64EncodedString(), "mimeType": mime],
                ["type": "text", "text": caption],
            ]
        ]
    }

    func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }

    func call(_ method: String, _ path: String, body: Any? = nil) throws -> APIResponse {
        try transport(method, "/v1" + path, try body.map(json))
    }

    func callTool(_ name: String, _ args: [String: Any]) throws -> [String: Any] {
        switch name {
        case "simpleskp_state":
            return textResult(try call("GET", "/state"))
        case "simpleskp_help":
            return textResult(try call("GET", "/help"))
        case "simpleskp_open":
            return textResult(try call("POST", "/open", body: args))
        case "simpleskp_camera":
            if args.isEmpty {
                return textResult(try call("GET", "/camera"))
            }
            return textResult(try call("POST", "/camera", body: args))
        case "simpleskp_scene":
            return textResult(try call("POST", "/scene", body: args))
        case "simpleskp_layers":
            return textResult(try call("POST", "/layers", body: args))
        case "simpleskp_rendering":
            return textResult(try call("POST", "/rendering", body: args))
        case "simpleskp_snapshot":
            if (args["format"] as? String)?.lowercased() == "pdf" || args["path"] != nil {
                return textResult(try call("POST", "/pdf", body: args))
            }
            let response = try call("GET", "/snapshot.png")
            return imageResult(response, caption: "Snapshot of the SimpleSKP 3D viewport.")
        default:
            throw ProxyError.badArguments("unknown tool \(name)")
        }
    }
}

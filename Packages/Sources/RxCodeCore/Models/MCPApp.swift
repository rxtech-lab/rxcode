import Foundation

/// An App's HTML and a proxy scoped to the server that supplied it.
public struct MCPAppResource: Sendable {
    public let html: String
    public let tool: JSONValue
    public let call: @Sendable (String, JSONValue) async throws -> JSONValue

    public init(html: String, tool: JSONValue, call: @escaping @Sendable (String, JSONValue) async throws -> JSONValue) {
        self.html = html
        self.tool = tool
        self.call = call
    }

    public static func resourceURI(in tool: JSONValue) -> String? {
        let meta = tool["_meta"]
        guard let uri = meta?["ui"]?["resourceUri"]?.stringValue ?? meta?["ui/resourceUri"]?.stringValue,
              uri.hasPrefix("ui://") else { return nil }
        return uri
    }

    public static func permitsAppCall(_ tool: JSONValue) -> Bool {
        guard let visibility = tool["_meta"]?["ui"]?["visibility"]?.arrayValue else { return true }
        return visibility.contains(.string("app"))
    }

    /// Build policy from validated origins only. Resource HTML cannot loosen this policy.
    public static func contentSecurityPolicy(meta: JSONValue?) -> String {
        func domains(_ key: String) -> String {
            (meta?["csp"]?[key]?.arrayValue ?? []).compactMap { value -> String? in
                guard let text = value.stringValue, let url = URL(string: text),
                      url.scheme == "https", let host = url.host,
                      host.range(of: #"^[A-Za-z0-9.\[\]:-]+$"#, options: .regularExpression) != nil,
                      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                      url.path.isEmpty || url.path == "/" else { return nil }
                return "https://\(host)" + (url.port.map { ":\($0)" } ?? "")
            }.joined(separator: " ")
        }
        let resources = domains("resourceDomains")
        let connections = domains("connectDomains")
        let frames = domains("frameDomains")
        return "default-src 'none'; script-src 'unsafe-inline' \(resources); style-src 'unsafe-inline' \(resources); "
            + "img-src data: blob: \(resources); font-src data: \(resources); media-src data: blob: \(resources); "
            + "connect-src \(connections.isEmpty ? "'none'" : connections); "
            + "frame-src \(frames.isEmpty ? "'none'" : frames); object-src 'none'; base-uri 'none'; form-action 'none'"
    }
}

public typealias MCPAppLoader = @MainActor (ToolCall) async throws -> MCPAppResource?

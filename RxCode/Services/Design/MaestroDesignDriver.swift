import Foundation
import RxCodeCore

/// Maestro uses UIKit points. Its hierarchy supplies the logical bounds for the same device.
nonisolated struct MaestroDesignDriver {
    let executable: String
    let device: String

    func hierarchy() async throws -> JSONValue {
        let data = try await DesignCommand.run(executable, ["--device", device, "--no-ansi", "hierarchy"], timeout: 90)
        guard let start = data.firstIndex(of: 123), let end = data.lastIndex(of: 125), start <= end else {
            throw IDEToolError.handlerFailed("Maestro did not return the simulator accessibility hierarchy.")
        }
        return try JSONDecoder().decode(JSONValue.self, from: data[start...end])
    }

    static func bounds(_ name: String?) -> CGRect? {
        let parts = (name ?? "").split(whereSeparator: { "[],".contains($0) }).compactMap { Double($0) }
        guard parts.count == 4, parts[2] > parts[0], parts[3] > parts[1] else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2] - parts[0], height: parts[3] - parts[1])
    }

    static func hit(_ tree: JSONValue, fraction: CGPoint) throws -> (point: CGPoint, label: String) {
        func rect(_ node: JSONValue) -> CGRect? { bounds(node["attributes"]?["bounds"]?.stringValue) }
        let windows = (tree["children"]?.arrayValue ?? []).compactMap(rect)
        guard let screen = rect(tree) ?? windows.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
            throw IDEToolError.handlerFailed("Maestro did not report the simulator display bounds.")
        }
        let point = CGPoint(x: screen.minX + fraction.x * screen.width, y: screen.minY + fraction.y * screen.height)
        var label = "Selected screenshot region", area = CGFloat.greatestFiniteMagnitude
        func visit(_ node: JSONValue) {
            if let frame = rect(node), frame.contains(point), frame.width * frame.height <= area,
               let attributes = node["attributes"] {
                let fields = ["resource-id", "accessibilityText", "title", "text", "hintText"]
                    .compactMap { attributes[$0]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                if !fields.isEmpty {
                    label = fields.joined(separator: " · ")
                    area = frame.width * frame.height
                }
            }
            node["children"]?.arrayValue?.forEach(visit)
        }
        visit(tree)
        return (point, label)
    }

    func tap(_ fraction: CGPoint) async throws {
        let hit = try Self.hit(await hierarchy(), fraction: fraction)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rxcode-\(UUID()).yaml")
        defer { try? FileManager.default.removeItem(at: file) }
        let flow = "appId: com.apple.springboard\n---\n- tapOn:\n    point: \"\(Int(hit.point.x)),\(Int(hit.point.y))\"\n"
        try flow.write(to: file, atomically: true, encoding: .utf8)
        _ = try await DesignCommand.run(executable, ["--device", device, "--no-ansi", "test", file.path], timeout: 90)
    }

    func type(_ text: String) async throws {
        let connection = await MCPAppConnection(detail: .init(name: "Maestro", scope: .user, transport: .stdio, url: nil,
            command: executable, args: ["mcp"], env: [:]), timeoutSeconds: 90)
        let result = try await connection.callNativeTool("input_text", arguments: ["device_id": .string(device), "text": .string(text)])
        if result["isError"]?.boolValue == true {
            throw IDEToolError.handlerFailed(result["content"]?[0]?["text"]?.stringValue ?? "Maestro could not type on this simulator.")
        }
    }
}

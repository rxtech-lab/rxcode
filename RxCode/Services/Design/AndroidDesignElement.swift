import Foundation

enum AndroidDesignElement {
    nonisolated static func at(_ point: CGPoint, in output: Data) -> String? {
        let text = String(decoding: output, as: UTF8.self)
        guard let start = text.range(of: "<hierarchy"), let end = text.range(of: "</hierarchy>", options: .backwards),
              start.lowerBound < end.upperBound,
              let document = try? XMLDocument(xmlString: String(text[start.lowerBound..<end.upperBound]), options: [.nodeLoadExternalEntitiesNever]),
              let nodes = try? document.nodes(forXPath: "//node") as? [XMLElement] else { return nil }
        var best: (area: CGFloat, details: String)?
        for node in nodes {
            func attribute(_ key: String) -> String { node.attribute(forName: key)?.stringValue ?? "" }
            guard let frame = MaestroDesignDriver.bounds(attribute("bounds")) else { continue }
            let area = frame.width * frame.height
            guard frame.contains(point), area <= best?.area ?? .greatestFiniteMagnitude else { continue }
            let name = attribute("password") == "true" ? "Secure text field" : String(attribute("text").prefix(200))
            best = (area, [attribute("class"), attribute("resource-id"), attribute("content-desc"), name, attribute("bounds")]
                .filter { !$0.isEmpty }.joined(separator: " · "))
        }
        return best?.details
    }
}

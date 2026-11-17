import AppKit
import Foundation
import ImageIO
import Observation
import RxCodeCore

/// A data-only appearance plugin. Packs never execute code.
nonisolated struct PetLook: Codable, Identifiable, Equatable, Sendable {
    var version = 1
    var id: String
    var name: String
    var hue: Double = 0
    var saturation: Double = 1
    var accessory: String = "none"
    var columns: Int = 6
    var rows: Int = 8
    /// Nil uses the bundled robot; imported packs use an app-owned atlas.
    var atlasPath: String?
    var atlasPaths: [String]?
    var sheetCount: Int?
    var preset: String?
    /// Coordinates relative to one cell, in the range 0...1.
    var mouth: PetAnimationManifest.Mouth?
    var hasSpeechFrames: Bool?

    static let accessories = ["none", "star", "heart", "crown"]
    static let builtins: [PetLook] = [
        .init(id: "rxcode-buddy", name: "Robot", sheetCount: 4, preset: "robot", hasSpeechFrames: true),
        .init(id: "dog-buddy", name: "Dog", sheetCount: 4, preset: "dog", hasSpeechFrames: true),
        .init(id: "cat-buddy", name: "Cat", sheetCount: 4, preset: "cat", hasSpeechFrames: true),
        .init(id: "round-buddy", name: "Puff", sheetCount: 4, preset: "puff", hasSpeechFrames: true)
    ]

    func validated() throws -> Self {
        guard version == 1, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 80, hue.isFinite, (0...360).contains(hue),
              saturation.isFinite, (0...2).contains(saturation),
              Self.accessories.contains(accessory), (1...24).contains(columns), rows == 8,
              (1...4).contains(sheetCount ?? 1),
              preset == nil || ["robot", "dog", "cat", "puff"].contains(preset ?? "") else {
            throw IDEToolError.invalidArguments("Invalid look. Use version 1, a name up to 80 characters, hue 0–360, saturation 0–2, a supported accessory, 1–24 columns and 8 motion rows.")
        }
        if let mouth {
            guard [mouth.x, mouth.y, mouth.width, mouth.height].allSatisfy(\.isFinite),
                  mouth.x >= 0, mouth.y >= 0, mouth.width > 0, mouth.height > 0,
                  mouth.x + mouth.width <= 1, mouth.y + mouth.height <= 1 else {
                throw IDEToolError.invalidArguments("Mouth coordinates must fit within a normalized sprite cell.")
            }
        }
        return self
    }

    var character: PetCharacter {
        var result = preset.map(PetCharacter.preset) ?? PetCharacter.rxcodeBuddy
        if let atlasPath {
            result = PetCharacter(id: id, displayName: name,
                spriteSheetURL: URL(fileURLWithPath: atlasPath), expressionsURL: nil,
                animationManifestURL: nil, frameColumns: columns, frameRows: rows,
                overlaysExpressions: false)
            if hasSpeechFrames == true {
                let sheets = atlasPaths ?? [atlasPath]
                result.closedMouthSheetURLs = sheets.map { URL(fileURLWithPath: String($0.dropLast(4)) + "-closed.png") }
                result.openMouthSheetURLs = sheets.map { URL(fileURLWithPath: String($0.dropLast(4)) + "-open.png") }
            }
        }
        result.additionalSpriteSheetURLs = (atlasPaths ?? []).dropFirst().map { URL(fileURLWithPath: $0) }
            + (atlasPath == nil ? result.additionalSpriteSheetURLs : [])
        if (sheetCount ?? 1) > 1 { result.spriteFrameDuration = 0.08 }
        result.speechMouth = mouth
        result.displayName = name
        result.lookHue = hue
        result.lookSaturation = saturation
        result.lookAccessory = accessory
        return result
    }
}

@MainActor @Observable
final class PetLookStore {
    private(set) var looks: [PetLook]
    private(set) var selectedID: String
    private let defaults: UserDefaults
    private let storageDirectory: URL?
    private static let looksKey = "pet.customLooks.v1"
    private static let selectionKey = "pet.selectedLook.v1"

    init(defaults: UserDefaults = .standard, storageDirectory: URL? = nil) {
        self.defaults = defaults
        self.storageDirectory = storageDirectory
        let saved = defaults.data(forKey: Self.looksKey)
            .flatMap { try? JSONDecoder().decode([PetLook].self, from: $0) } ?? []
        var ids = Set(PetLook.builtins.map(\.id))
        let available = PetLook.builtins + saved.filter {
            (try? $0.validated()) != nil && ids.insert($0.id).inserted
        }
        looks = available
        let id = defaults.string(forKey: Self.selectionKey) ?? PetLook.builtins[0].id
        selectedID = available.contains { $0.id == id } ? id : PetLook.builtins[0].id
        Task { [weak self] in await self?.consolidateDetailedDog() }
    }

    /// The original detailed pack became the bundled Dog. Keep its selection
    /// while removing an identical imported library entry; retain source files.
    func consolidateDetailedDog() async {
        guard let dog = PetLook.builtins.first(where: { $0.id == "dog-buddy" }) else { return }
        let candidates = looks.filter {
            !isBuiltin($0.id) && ["Dog", "Detailed Dog"].contains($0.name)
                && $0.hue == dog.hue && $0.saturation == dog.saturation
                && $0.accessory == dog.accessory && $0.columns == dog.columns
                && $0.rows == dog.rows && $0.sheetCount == dog.sheetCount
                && $0.hasSpeechFrames == dog.hasSpeechFrames && $0.mouth == dog.mouth
        }
        guard !candidates.isEmpty else { return }
        func sheets(_ look: PetLook) -> [URL] {
            let character = look.character
            return (character.spriteSheetURL.map { [$0] } ?? [])
                + character.additionalSpriteSheetURLs
                + character.closedMouthSheetURLs + character.openMouthSheetURLs
        }
        let bundled = sheets(dog)
        let sources = candidates.map { ($0.id, sheets($0)) }
        let duplicates = await Task.detached {
            Set(sources.compactMap { id, urls -> String? in
                guard urls.count == 12, bundled.count == 12,
                      zip(urls, bundled).allSatisfy({ FileManager.default.contentsEqual(atPath: $0.path, andPath: $1.path) }) else { return nil }
                return id
            })
        }.value
        // A user may edit a look while the file comparison runs.
        let removable = Set(candidates.filter { duplicates.contains($0.id) && looks.contains($0) }.map(\.id))
        guard !removable.isEmpty else { return }
        let updated = looks.filter { !removable.contains($0.id) }
        guard let data = try? JSONEncoder().encode(updated.filter { !isBuiltin($0.id) }) else { return }
        defaults.set(data, forKey: Self.looksKey)
        looks = updated
        if removable.contains(selectedID) { try? select(dog.id) }
    }

    var selected: PetLook { looks.first { $0.id == selectedID } ?? PetLook.builtins[0] }
    func isBuiltin(_ id: String) -> Bool { PetLook.builtins.contains { $0.id == id } }

    func select(_ id: String) throws {
        guard looks.contains(where: { $0.id == id }) else { throw IDEToolError.invalidArguments("Unknown pet look ID.") }
        selectedID = id
        defaults.set(id, forKey: Self.selectionKey)
    }

    func save(_ look: PetLook) throws {
        let look = try look.validated()
        guard !isBuiltin(look.id) else { throw IDEToolError.invalidArguments("Duplicate a built-in look before editing it.") }
        var updated = looks
        if let index = updated.firstIndex(where: { $0.id == look.id }) { updated[index] = look }
        else { updated.append(look) }
        let data = try JSONEncoder().encode(updated.filter { !isBuiltin($0.id) })
        defaults.set(data, forKey: Self.looksKey)
        looks = updated
        try select(look.id)
    }

    func remove(_ id: String) throws {
        guard !isBuiltin(id), looks.contains(where: { $0.id == id }) else {
            throw IDEToolError.invalidArguments("Choose a saved custom look to remove.")
        }
        let updated = looks.filter { $0.id != id }
        defaults.set(try JSONEncoder().encode(updated.filter { !isBuiltin($0.id) }), forKey: Self.looksKey)
        looks = updated
        if selectedID == id { try select(PetLook.builtins[0].id) }
    }

    /// Read and decode off the main actor, then publish atomically to all pet views.
    func preparePack(at folder: URL) async throws -> PetLook {
        let storageDirectory = self.storageDirectory
        let look = try await Task.detached { () throws -> PetLook in
            let manifest = folder.appendingPathComponent("look.json")
            let values = try manifest.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= 16_384 else { throw IDEToolError.invalidArguments("Look manifest exceeds 16 KB.") }
            var look = try JSONDecoder().decode(PetLook.self, from: Data(contentsOf: manifest)).validated()
            let atlases = (0..<(look.sheetCount ?? 1)).map { index in
                folder.appendingPathComponent(index == 0 ? "atlas.png" : "atlas-\(index + 1).png")
            }
            var totalPixels = 0
            var files = atlases
            func validate(_ atlas: URL, expected: (Int, Int)? = nil) throws -> (Int, Int) {
                let size = try atlas.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 32 * 1024 * 1024,
                      let source = CGImageSourceCreateWithURL(atlas as CFURL, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = props[kCGImagePropertyPixelWidth] as? Int,
                      let height = props[kCGImagePropertyPixelHeight] as? Int,
                      width <= 8192, height <= 8192, width >= look.columns, height >= look.rows,
                      width % look.columns == 0, height % look.rows == 0,
                      CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
                    throw IDEToolError.invalidArguments("Each sheet must be a valid image up to 32 MB and 8192×8192 pixels, evenly divided into its frame grid.")
                }
                if let expected, expected != (width, height) {
                    throw IDEToolError.invalidArguments("Open and closed mouth sheets must match their body sheet's dimensions and grid.")
                }
                totalPixels += width * height
                guard totalPixels <= 67_108_864 else { throw IDEToolError.invalidArguments("The pack exceeds the 64 megapixel animation budget, including speech sheets.") }
                return (width, height)
            }
            for atlas in atlases {
                let dimensions = try validate(atlas)
                if look.hasSpeechFrames == true {
                    for state in ["closed", "open"] {
                        let speech = atlas.deletingLastPathComponent().appendingPathComponent(atlas.deletingPathExtension().lastPathComponent + "-\(state).png")
                        _ = try validate(speech, expected: dimensions)
                        files.append(speech)
                    }
                }
            }
            look.id = UUID().uuidString
            let base = try storageDirectory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("RxCode/PetLooks")
            let root = base.appendingPathComponent(look.id)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var paths: [String] = []
            for atlas in files {
                let destination = root.appendingPathComponent(atlas.lastPathComponent)
                try FileManager.default.copyItem(at: atlas, to: destination)
                if atlases.contains(atlas) { paths.append(destination.path) }
            }
            look.atlasPath = paths[0]
            look.atlasPaths = paths
            look.preset = nil
            return look
        }.value
        return look
    }

    func importPack(at folder: URL) async throws {
        let look = try await preparePack(at: folder)
        try save(look)
    }

    /// Write a portable pack to a fresh folder; never overwrite user files.
    func exportPack(id: String, to parent: URL? = nil) async throws -> URL {
        guard var look = looks.first(where: { $0.id == id }), let atlas = look.character.spriteSheetURL else {
            throw IDEToolError.invalidArguments("The look or its sprite atlas is unavailable.")
        }
        let character = look.character
        let atlases = [atlas] + character.additionalSpriteSheetURLs
        let hasSpeech = character.closedMouthSheetURLs.count == atlases.count && character.openMouthSheetURLs.count == atlases.count
        look.hasSpeechFrames = hasSpeech
        look.atlasPath = nil
        look.atlasPaths = nil
        look.preset = nil
        look.sheetCount = atlases.count
        let portable = look
        return try await Task.detached {
            let desktop = try parent ?? FileManager.default.url(for: .desktopDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            let name = portable.name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }.joined()
            let folder = desktop.appendingPathComponent("Pet-\(name)-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            do {
                for (index, atlas) in atlases.enumerated() {
                    let filename = index == 0 ? "atlas.png" : "atlas-\(index + 1).png"
                    try FileManager.default.copyItem(at: atlas, to: folder.appendingPathComponent(filename))
                    if hasSpeech {
                        let stem = String(filename.dropLast(4))
                        try FileManager.default.copyItem(at: character.closedMouthSheetURLs[index], to: folder.appendingPathComponent(stem + "-closed.png"))
                        try FileManager.default.copyItem(at: character.openMouthSheetURLs[index], to: folder.appendingPathComponent(stem + "-open.png"))
                    }
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(portable).write(to: folder.appendingPathComponent("look.json"), options: .atomic)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
            return folder
        }.value
    }

    func handle(_ args: JSONValue) async throws -> JSONValue {
        var exportedPath: String?
        switch args["action"]?.stringValue {
        case "guide":
            return .object(["skill": .string(try PetLookSkill.instructions())])
        case "export":
            exportedPath = try await exportPack(id: args["id"]?.stringValue ?? selectedID).path
        case "list": break
        case "set":
            guard let id = args["id"]?.stringValue else { throw IDEToolError.invalidArguments("id is required.") }
            try select(id)
        case "save":
            let source = args["id"]?.stringValue ?? selectedID
            guard var look = looks.first(where: { $0.id == source }), let name = args["name"]?.stringValue else {
                throw IDEToolError.invalidArguments("Provide a name and an existing source look ID.")
            }
            // Agent customization creates a new variant, preserving the source.
            look.id = UUID().uuidString
            look.name = name
            if let value = args["hue"] { guard let n = value.numberValue else { throw IDEToolError.invalidArguments("hue must be a number.") }; look.hue = n }
            if let value = args["saturation"] { guard let n = value.numberValue else { throw IDEToolError.invalidArguments("saturation must be a number.") }; look.saturation = n }
            if let value = args["accessory"] {
                guard let accessory = value.stringValue else { throw IDEToolError.invalidArguments("accessory must be a string.") }
                look.accessory = accessory
            }
            try save(look)
        case "import":
            guard let path = args["path"]?.stringValue, path.hasPrefix("/") else { throw IDEToolError.invalidArguments("An absolute pack folder path is required.") }
            try await importPack(at: URL(fileURLWithPath: path))
        default: throw IDEToolError.invalidArguments("Use guide, list, set, save, import or export.")
        }
        var result: [String: JSONValue] = ["selected_id": .string(selectedID), "looks": .array(looks.map {
            .object(["id": .string($0.id), "name": .string($0.name), "hue": .number($0.hue),
                     "saturation": .number($0.saturation), "accessory": .string($0.accessory)])
        })]
        if let exportedPath { result["exported_path"] = .string(exportedPath) }
        return .object(result)
    }
}

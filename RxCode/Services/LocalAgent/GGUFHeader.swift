import Foundation

/// Reads `general.architecture` from a GGUF header without loading tensors.
nonisolated enum GGUFHeader {
    enum ReadError: Error { case notGGUF, truncated, unsupportedType(UInt32) }

    /// `nil` when the file is valid GGUF but declares no architecture.
    static func architecture(of url: URL) throws -> String? {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard try file.read(upToCount: 4) == Data("GGUF".utf8) else { throw ReadError.notGGUF }
        _ = try read(UInt32.self, file) // version
        _ = try read(UInt64.self, file) // tensor count
        let count = try read(UInt64.self, file)
        for _ in 0..<min(count, 4_096) {
            let key = try readString(file)
            let type = try read(UInt32.self, file)
            if key == "general.architecture", type == 8 {
                let value = try readString(file)
                return value.isEmpty ? nil : value
            }
            try skipValue(type: type, file)
        }
        return nil
    }

    private static func read<T: FixedWidthInteger>(_: T.Type, _ file: FileHandle) throws -> T {
        let size = MemoryLayout<T>.size
        guard let data = try file.read(upToCount: size), data.count == size else { throw ReadError.truncated }
        return T(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(as: T.self) })
    }

    private static func readString(_ file: FileHandle) throws -> String {
        let length = try read(UInt64.self, file)
        guard length <= 1_048_576 else { throw ReadError.truncated }
        guard length > 0 else { return "" }
        guard let data = try file.read(upToCount: Int(length)), data.count == Int(length) else { throw ReadError.truncated }
        return String(decoding: data, as: UTF8.self)
    }

    private static func skipValue(type: UInt32, _ file: FileHandle) throws {
        switch type {
        case 8:
            let length = try read(UInt64.self, file)
            try file.seek(toOffset: try file.offset() + length)
        case 9:
            let elementType = try read(UInt32.self, file)
            let count = try read(UInt64.self, file)
            if let size = fixedSize(elementType) {
                try file.seek(toOffset: try file.offset() + count * size)
            } else {
                for _ in 0..<count { try skipValue(type: elementType, file) }
            }
        default:
            guard let size = fixedSize(type) else { throw ReadError.unsupportedType(type) }
            try file.seek(toOffset: try file.offset() + size)
        }
    }

    static func fixedSize(_ type: UInt32) -> UInt64? {
        switch type {
        case 0, 1, 7: 1
        case 2, 3: 2
        case 4, 5, 6: 4
        case 10, 11, 12: 8
        default: nil
        }
    }
}

extension GGUFHeader {
    /// The `general.*` string and number entries in the first bytes of a GGUF
    /// file, e.g. from a range request. Stops quietly where the bytes run out,
    /// since big arrays (the tokenizer) usually follow the `general` block.
    nonisolated static func generalMetadata(in data: Data) -> [String: String] {
        var cursor = Cursor(data: data)
        guard cursor.bytes(4) == Data("GGUF".utf8),
              cursor.integer(UInt32.self) != nil, cursor.integer(UInt64.self) != nil,
              let count = cursor.integer(UInt64.self) else { return [:] }
        var metadata: [String: String] = [:]
        for _ in 0..<min(count, 4_096) {
            guard let key = cursor.string(), let type = cursor.integer(UInt32.self) else { break }
            let isGeneral = key.hasPrefix("general.")
            switch type {
            case 8:
                guard let value = cursor.string() else { return metadata }
                if isGeneral, !value.isEmpty { metadata[key] = String(value.prefix(200)) }
            case 4, 5:
                guard let value = cursor.integer(UInt32.self) else { return metadata }
                if isGeneral { metadata[key] = type == 4 ? String(value) : String(Int32(bitPattern: value)) }
            case 10, 11:
                guard let value = cursor.integer(UInt64.self) else { return metadata }
                if isGeneral { metadata[key] = type == 10 ? String(value) : String(Int64(bitPattern: value)) }
            case 9:
                guard let elementType = cursor.integer(UInt32.self), let length = cursor.integer(UInt64.self) else { return metadata }
                if let size = fixedSize(elementType) {
                    guard cursor.skip(length * size) else { return metadata }
                } else if elementType == 8 {
                    for _ in 0..<length { guard cursor.string() != nil else { return metadata } }
                } else {
                    return metadata
                }
            default:
                guard let size = fixedSize(type), cursor.skip(size) else { return metadata }
            }
        }
        return metadata
    }

    private nonisolated struct Cursor {
        let data: Data
        var offset = 0

        mutating func bytes(_ count: Int) -> Data? {
            guard count >= 0, offset + count <= data.count else { return nil }
            defer { offset += count }
            let start = data.startIndex + offset
            return data[start..<start + count]
        }

        mutating func integer<T: FixedWidthInteger>(_: T.Type) -> T? {
            bytes(MemoryLayout<T>.size).map { T(littleEndian: $0.withUnsafeBytes { $0.loadUnaligned(as: T.self) }) }
        }

        mutating func string() -> String? {
            guard let length = integer(UInt64.self), length <= 1_048_576, let raw = bytes(Int(length)) else { return nil }
            return String(decoding: raw, as: UTF8.self)
        }

        mutating func skip(_ count: UInt64) -> Bool {
            guard count <= UInt64(data.count - offset) else { return false }
            offset += Int(count)
            return true
        }
    }
}

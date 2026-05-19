import Foundation

extension Data {
    /// Strips `//` line comments and `/* … */` block comments from JSONC-style
    /// data while leaving string literals and line endings intact. Used to
    /// preprocess shortcut and slash-command config files before handing them
    /// to `JSONDecoder`.
    func removingJSONComments() -> Data {
        let bytes = Array(self)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)

        var index = 0
        var isInString = false
        var isEscaped = false
        var isInLineComment = false
        var isInBlockComment = false

        while index < bytes.count {
            let byte = bytes[index]
            let next = index + 1 < bytes.count ? bytes[index + 1] : nil

            if isInLineComment {
                if byte == 0x0A || byte == 0x0D {
                    isInLineComment = false
                    output.append(byte)
                }
                index += 1
                continue
            }

            if isInBlockComment {
                if byte == 0x2A, next == 0x2F {
                    isInBlockComment = false
                    index += 2
                } else {
                    if byte == 0x0A || byte == 0x0D {
                        output.append(byte)
                    }
                    index += 1
                }
                continue
            }

            if isInString {
                output.append(byte)
                if isEscaped {
                    isEscaped = false
                } else if byte == 0x5C {
                    isEscaped = true
                } else if byte == 0x22 {
                    isInString = false
                }
                index += 1
                continue
            }

            if byte == 0x22 {
                isInString = true
                output.append(byte)
                index += 1
            } else if byte == 0x2F, next == 0x2F {
                isInLineComment = true
                index += 2
            } else if byte == 0x2F, next == 0x2A {
                isInBlockComment = true
                index += 2
            } else {
                output.append(byte)
                index += 1
            }
        }

        return Data(output)
    }
}

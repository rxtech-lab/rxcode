import Foundation

// MARK: - Spoken Text Chunker

/// Cleans streamed Markdown / code output into natural spoken text and slices
/// it on sentence boundaries so local TTS can begin speaking before the full
/// turn finishes.
nonisolated struct SpokenTextChunker: Sendable {
    var minimumChunkCharacters: Int = 18
    var softMaximumCharacters: Int = 200

    private var rawBuffer: String = ""
    private var insideCodeFence: Bool = false

    init(minimumChunkCharacters: Int = 18, softMaximumCharacters: Int = 200) {
        self.minimumChunkCharacters = minimumChunkCharacters
        self.softMaximumCharacters = softMaximumCharacters
    }

    /// Append a streamed text delta and return any complete speakable sentences.
    mutating func append(_ delta: String) -> [String] {
        guard !delta.isEmpty else { return [] }
        rawBuffer += delta
        return drainReadySentences(forceAll: false)
    }

    /// Flush any remaining buffered text at a tool call boundary or turn end.
    mutating func flush() -> [String] {
        defer {
            rawBuffer = ""
            insideCodeFence = false
        }
        return drainReadySentences(forceAll: true)
    }

    mutating func reset() {
        rawBuffer = ""
        insideCodeFence = false
    }

    /// Sanitize an entire Markdown string into plain, natural spoken prose.
    static func sanitizeForSpeech(_ markdown: String) -> String {
        guard !markdown.isEmpty else { return "" }
        var text = markdown

        // Remove fenced code blocks completely (reading raw code aloud is noisy).
        text = replacingRegex(
            in: text,
            pattern: "```[\\s\\S]*?```",
            with: " "
        )
        // Strip unclosed trailing code fence if present.
        if let fenceRange = text.range(of: "```") {
            text = String(text[..<fenceRange.lowerBound])
        }

        // Convert markdown links [label](url) -> label.
        text = replacingRegex(
            in: text,
            pattern: "\\[([^\\]]+)\\]\\((?:[^)\\s]+)\\)",
            with: "$1"
        )

        // Strip bare URLs.
        text = replacingRegex(
            in: text,
            pattern: "https?://[^\\s)\\]>]+",
            with: " "
        )

        // Unwrap inline code spans `symbol` -> symbol.
        text = text.replacingOccurrences(of: "`", with: "")

        // Strip Markdown headings, blockquote markers, and list bullets at line starts.
        text = replacingRegex(
            in: text,
            pattern: "(?m)^\\s*(?:#{1,6}\\s+|[-*+]\\s+|\\d+\\.\\s+|>\\s+)",
            with: ""
        )

        // Remove emphasis markers (*, **, _, __, ~~).
        text = replacingRegex(
            in: text,
            pattern: "(\\*\\*|__|~~|\\*|_)",
            with: ""
        )

        // Collapse multiple spaces while preserving paragraph breaks as pauses.
        text = replacingRegex(in: text, pattern: "[ \\t]+", with: " ")
        text = replacingRegex(in: text, pattern: "\\n{2,}", with: ". ")
        text = replacingRegex(in: text, pattern: "\\n", with: " ")
        text = replacingRegex(in: text, pattern: "\\.\\s*\\.+", with: ".")
        text = replacingRegex(in: text, pattern: "\\s+([.,!?;:])", with: "$1")
        text = replacingRegex(in: text, pattern: "\\s{2,}", with: " ")

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Use the same bounded sentence generation for complete reports and streamed replies.
    static func speechChunks(_ text: String) -> [String] {
        var chunker = SpokenTextChunker()
        return chunker.append(text) + chunker.flush()
    }

    // MARK: - Private

    private mutating func drainReadySentences(forceAll: Bool) -> [String] {
        // Strip complete code fences out of rawBuffer first; if we're currently inside
        // an unclosed fence and not forcing flush, wait until it closes.
        while let start = rawBuffer.range(of: "```") {
            let afterStart = rawBuffer[start.upperBound...]
            if let end = afterStart.range(of: "```") {
                rawBuffer.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                if forceAll {
                    rawBuffer.removeSubrange(start.lowerBound..<rawBuffer.endIndex)
                } else {
                    // Emit anything before the opening fence, keep the unclosed fence buffered.
                    let prefix = String(rawBuffer[..<start.lowerBound])
                    rawBuffer = String(rawBuffer[start.lowerBound...])
                    let cleanedPrefix = Self.sanitizeForSpeech(prefix)
                    return cleanedPrefix.isEmpty ? [] : [cleanedPrefix]
                }
                break
            }
        }

        var chunks: [String] = []

        while !rawBuffer.isEmpty {
            if let splitIdx = nextSplitIndex(in: rawBuffer) {
                let candidateRaw = String(rawBuffer[..<splitIdx])
                rawBuffer = String(rawBuffer[splitIdx...])
                let cleaned = Self.sanitizeForSpeech(candidateRaw)
                if !cleaned.isEmpty {
                    if let last = chunks.last, last.count < minimumChunkCharacters {
                        chunks[chunks.count - 1] = "\(last) \(cleaned)"
                    } else {
                        chunks.append(cleaned)
                    }
                }
            } else if forceAll {
                let cleaned = Self.sanitizeForSpeech(rawBuffer)
                rawBuffer = ""
                if !cleaned.isEmpty {
                    if let last = chunks.last, last.count < minimumChunkCharacters {
                        chunks[chunks.count - 1] = "\(last) \(cleaned)"
                    } else {
                        chunks.append(cleaned)
                    }
                }
            } else {
                break
            }
        }

        // If not forcing all, hold back a tiny trailing fragment so it merges naturally with the next sentence.
        if !forceAll, chunks.count == 1, chunks[0].count < minimumChunkCharacters {
            rawBuffer = chunks[0] + " " + rawBuffer
            return []
        }

        return chunks
    }

    private func nextSplitIndex(in text: String) -> String.Index? {
        let hardTerminators: Set<Character> = [".", "!", "?", "。", "！", "？", "\n"]
        let softTerminators: Set<Character> = [";", ":", ",", "；", "：", "，"]

        var count = 0
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            let next = text.index(after: index)
            count += 1

            if hardTerminators.contains(ch), count >= minimumChunkCharacters {
                // Avoid splitting inside decimal numbers like "1.4" or "v2.0"
                if ch == ".", next < text.endIndex, text[next].isNumber {
                    index = next
                    continue
                }
                if ch == "\n" {
                    return next
                }
                // Require whitespace or end-of-CJK punctuation after ASCII sentence punctuation
                if ch == "。" || ch == "！" || ch == "？" {
                    return next
                }
                if next < text.endIndex, text[next].isWhitespace {
                    return next
                }
            }

            if count >= softMaximumCharacters, softTerminators.contains(ch) {
                return next
            }
            if count >= softMaximumCharacters + 60,
               ch.isWhitespace || count >= softMaximumCharacters + 120 {
                return next
            }

            index = next
        }
        return nil
    }

    private static func replacingRegex(in input: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return input
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: template)
    }
}

// MARK: - Voice Activity / Utterance Detector

nonisolated enum UtteranceEvent: Equatable, Sendable {
    case none
    case speechStarted
    case speechContinuing
    case speechEnded
    case idleTimeout
}

/// Adaptive noise-floor RMS voice activity detector for 16-bit PCM frames.
nonisolated struct UtteranceDetector: Sendable {
    var minimumSpeechThreshold: Float = 0.016
    var noiseMultiplier: Float = 2.8
    var speechActivationDuration: TimeInterval = 0.14
    var silenceCompletionDuration: TimeInterval = 0.78
    var maximumUtteranceDuration: TimeInterval = 24.0
    var idleResetDuration: TimeInterval = 45.0

    private(set) var noiseFloor: Float = 0.004
    private(set) var isSpeaking: Bool = false
    private var aboveThresholdDuration: TimeInterval = 0
    private var silenceDuration: TimeInterval = 0
    private var utteranceDuration: TimeInterval = 0
    private var idleDuration: TimeInterval = 0

    init() {}

    mutating func reset() {
        isSpeaking = false
        aboveThresholdDuration = 0
        silenceDuration = 0
        utteranceDuration = 0
        idleDuration = 0
    }

    mutating func process(rms: Float, frameDuration: TimeInterval) -> UtteranceEvent {
        let dt = max(0.001, frameDuration)
        let threshold = max(minimumSpeechThreshold, noiseFloor * noiseMultiplier)

        if !isSpeaking {
            if rms < threshold {
                // Smoothly adapt ambient noise floor while user is silent
                noiseFloor = min(0.04, max(0.001, noiseFloor * 0.96 + rms * 0.04))
                aboveThresholdDuration = max(0, aboveThresholdDuration - dt * 0.5)
                idleDuration += dt
                if idleDuration >= idleResetDuration {
                    idleDuration = 0
                    return .idleTimeout
                }
                return .none
            } else {
                idleDuration = 0
                aboveThresholdDuration += dt
                if aboveThresholdDuration >= speechActivationDuration {
                    isSpeaking = true
                    utteranceDuration = aboveThresholdDuration
                    silenceDuration = 0
                    return .speechStarted
                }
                return .none
            }
        } else {
            utteranceDuration += dt
            if rms >= threshold * 0.75 {
                silenceDuration = 0
                if utteranceDuration >= maximumUtteranceDuration {
                    reset()
                    return .speechEnded
                }
                return .speechContinuing
            } else {
                silenceDuration += dt
                if silenceDuration >= silenceCompletionDuration || utteranceDuration >= maximumUtteranceDuration {
                    reset()
                    return .speechEnded
                }
                return .speechContinuing
            }
        }
    }

    static func rms(pcm16LE data: Data) -> Float {
        let sampleCount = data.count / 2
        guard sampleCount > 0 else { return 0 }
        var sumSquares: Double = 0
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                let normalized = Double(Int16(littleEndian: samples[i])) / 32768.0
                sumSquares += normalized * normalized
            }
        }
        return Float(sqrt(sumSquares / Double(sampleCount)))
    }
}

// MARK: - Codex Config Override Helper

nonisolated enum CodexConfigOverrideParser {
    static let realtimeFeatureOverrides: [String] = [
        "features.computer_use=false",
        "features.browser_use=false",
        "features.browser_use_external=false",
        "features.apps=false",
    ]

    /// `MCPService.codexConfigOverrides` returns CLI flag pairs `["-c", "k=v", "-c", "k2=v2"]`,
    /// whereas `RxAgentClients.CodexClient(configOverrides:)` prepends `-c` to each entry itself.
    /// Extracts bare `key=value` strings and appends safe realtime feature flags.
    static func extractBareOverrides(from cliPairs: [String], includeRealtimeFeatureGuards: Bool = true) -> [String] {
        var result: [String] = []
        var index = 0
        while index < cliPairs.count {
            let token = cliPairs[index]
            if token == "-c" || token == "--config" {
                if index + 1 < cliPairs.count {
                    result.append(cliPairs[index + 1])
                    index += 2
                    continue
                }
            } else if token == "--disable" {
                index += 2
                continue
            } else if token.contains("=") {
                result.append(token)
            }
            index += 1
        }
        if includeRealtimeFeatureGuards {
            for guardEntry in realtimeFeatureOverrides where !result.contains(guardEntry) {
                result.append(guardEntry)
            }
        }
        return result
    }
}

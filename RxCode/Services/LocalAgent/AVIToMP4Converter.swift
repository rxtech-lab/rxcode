import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ImageIO

/// Turns stable-diffusion.cpp's AVI output (MJPEG video, 16-bit PCM audio)
/// into an H.264/AAC MP4 that AVKit and WebKit play.
///
/// sd-cli's other video containers don't work on macOS: its WebM carries PCM
/// audio, which WebM players reject, and an image sequence drops the audio.
nonisolated enum AVIToMP4Converter {
    enum ConversionError: LocalizedError {
        case notAVI
        case noVideo
        case unsupportedAudio(String)
        case undecodableFrame(Int)
        case writer(String)

        var errorDescription: String? {
            switch self {
            case .notAVI: "The generated file is not an AVI video."
            case .noVideo: "The generated video has no frames."
            case .unsupportedAudio(let detail): "The generated audio track can't be converted: \(detail)."
            case .undecodableFrame(let index): "Frame \(index) of the generated video could not be decoded."
            case .writer(let detail): "Could not write the MP4: \(detail)"
            }
        }
    }

    /// The streams of an MJPEG/PCM AVI, read into memory. sd-cli clips are a
    /// few megabytes, so nothing is streamed.
    struct AVIContents {
        var framesPerSecond: Double = 24
        var width = 0
        var height = 0
        var jpegFrames: [Data] = []
        var audio: AudioFormat?
        var pcm = Data()

        struct AudioFormat: Equatable {
            let sampleRate: Double
            let channels: Int
            let bitsPerSample: Int
        }
    }

    /// Converts `avi` to `mp4`, replacing any file there.
    static func convert(avi: URL, to mp4: URL) async throws {
        // AVAssetWriter is driven with blocking waits, so keep it off the
        // cooperative thread pool.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try write(parse(Data(contentsOf: avi, options: .mappedIfSafe)), to: mp4)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - AVI parsing

    static func parse(_ data: Data) throws -> AVIContents {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, fourCC(bytes, 0) == "RIFF", fourCC(bytes, 8) == "AVI " else { throw ConversionError.notAVI }
        var contents = AVIContents()
        // Stream numbers in chunk IDs ("00dc", "01wb") follow `strl` order.
        var streamKinds: [String] = []
        walk(bytes, from: 12, to: bytes.count) { id, start, size in
            switch id {
            case "strh":
                guard size >= 32 else { return }
                let kind = fourCC(bytes, start)
                streamKinds.append(kind)
                let scale = Double(uint32(bytes, start + 20)), rate = Double(uint32(bytes, start + 24))
                if kind == "vids", scale > 0, rate > 0 { contents.framesPerSecond = rate / scale }
            case "strf":
                if streamKinds.last == "vids", size >= 12 {
                    contents.width = Int(Int32(bitPattern: uint32(bytes, start + 4)))
                    contents.height = abs(Int(Int32(bitPattern: uint32(bytes, start + 8))))
                } else if streamKinds.last == "auds", size >= 16 {
                    contents.audio = .init(
                        sampleRate: Double(uint32(bytes, start + 4)),
                        channels: Int(uint16(bytes, start + 2)),
                        bitsPerSample: Int(uint16(bytes, start + 14))
                    )
                    let formatTag = uint16(bytes, start)
                    if formatTag != 1 { contents.audio = nil }
                }
            default:
                guard id.count == 4, let stream = Int(id.prefix(2)), stream < streamKinds.count else { return }
                let payload = Data(bytes[start..<start + size])
                switch streamKinds[stream] {
                case "vids" where id.hasSuffix("dc") || id.hasSuffix("db"): contents.jpegFrames.append(payload)
                case "auds" where id.hasSuffix("wb"): contents.pcm.append(payload)
                default: break
                }
            }
        }
        guard !contents.jpegFrames.isEmpty else { throw ConversionError.noVideo }
        return contents
    }

    /// Visits every leaf chunk, descending into `LIST`s. Chunks pad to even sizes.
    private static func walk(_ bytes: [UInt8], from start: Int, to end: Int, visit: (String, Int, Int) -> Void) {
        var offset = start
        while offset + 8 <= end {
            let id = fourCC(bytes, offset)
            let size = Int(uint32(bytes, offset + 4))
            let body = offset + 8
            guard body + size <= end else { return }
            if id == "LIST" || id == "RIFF" {
                walk(bytes, from: body + 4, to: body + size, visit: visit)
            } else {
                visit(id, body, size)
            }
            offset = body + size + (size & 1)
        }
    }

    private static func fourCC(_ bytes: [UInt8], _ offset: Int) -> String {
        String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private static func uint16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    // MARK: - MP4 writing

    private static func write(_ contents: AVIContents, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let frames = try contents.jpegFrames.enumerated().map { index, data in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ConversionError.undecodableFrame(index) }
            return image
        }
        let width = contents.width > 0 ? contents.width : frames[0].width
        let height = contents.height > 0 ? contents.height : frames[0].height

        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: .mp4) } catch { throw ConversionError.writer(error.localizedDescription) }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(video)

        var audioInput: AVAssetWriterInput?
        var audioBuffers: [CMSampleBuffer] = []
        if let format = contents.audio, !contents.pcm.isEmpty {
            guard format.bitsPerSample == 16, format.channels > 0 else {
                throw ConversionError.unsupportedAudio("\(format.bitsPerSample)-bit, \(format.channels) channels")
            }
            audioBuffers = try pcmSampleBuffers(contents.pcm, format: format)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channels, AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else { throw ConversionError.writer(writer.error?.localizedDescription ?? "could not start") }
        writer.startSession(atSourceTime: .zero)

        // Each input pulls on its own queue so the writer can interleave them.
        let group = DispatchGroup()
        let frameDuration = CMTime(seconds: 1 / contents.framesPerSecond, preferredTimescale: 600)
        feed(video, queue: "video", count: frames.count, group: group) { index in
            guard let pool = adaptor.pixelBufferPool, let buffer = pixelBuffer(from: frames[index], pool: pool) else { return false }
            return adaptor.append(buffer, withPresentationTime: CMTimeMultiply(frameDuration, multiplier: Int32(index)))
        }
        if let audioInput {
            feed(audioInput, queue: "audio", count: audioBuffers.count, group: group) { audioInput.append(audioBuffers[$0]) }
        }
        group.wait()

        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            throw ConversionError.writer(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
    }

    /// Appends `count` items whenever `input` is ready, then marks it finished.
    private static func feed(
        _ input: AVAssetWriterInput, queue label: String, count: Int, group: DispatchGroup, append: @escaping (Int) -> Bool
    ) {
        let feeder = Feeder(input: input, count: count, group: group, append: append)
        group.enter()
        input.requestMediaDataWhenReady(on: DispatchQueue(label: "com.rxlab.RxCode.mp4-writer.\(label)")) { feeder.pull() }
    }

    /// AVFoundation only calls `pull` on the input's serial queue, so its
    /// state is never touched concurrently.
    private final class Feeder: @unchecked Sendable {
        let input: AVAssetWriterInput
        let count: Int
        let group: DispatchGroup
        let append: (Int) -> Bool
        var next = 0
        var finished = false

        init(input: AVAssetWriterInput, count: Int, group: DispatchGroup, append: @escaping (Int) -> Bool) {
            self.input = input
            self.count = count
            self.group = group
            self.append = append
        }

        func pull() {
            while input.isReadyForMoreMediaData && !finished {
                if next >= count || !append(next) {
                    finished = true
                    input.markAsFinished()
                    group.leave()
                    return
                }
                next += 1
            }
        }
    }

    private static func pixelBuffer(from image: CGImage, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    /// Interleaved little-endian PCM, cut into one-second sample buffers.
    static func pcmSampleBuffers(_ pcm: Data, format: AVIContents.AudioFormat) throws -> [CMSampleBuffer] {
        let bytesPerFrame = format.channels * 2
        var description = AudioStreamBasicDescription(
            mSampleRate: format.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame), mFramesPerPacket: 1, mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(format.channels), mBitsPerChannel: 16, mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else { throw ConversionError.unsupportedAudio("format \(status)") }

        let totalFrames = pcm.count / bytesPerFrame
        let chunkFrames = Int(format.sampleRate)
        var buffers: [CMSampleBuffer] = []
        var startFrame = 0
        while startFrame < totalFrames {
            let frames = min(chunkFrames, totalFrames - startFrame)
            let bytes = pcm.subdata(in: startFrame * bytesPerFrame..<(startFrame + frames) * bytesPerFrame)
            var block: CMBlockBuffer?
            status = CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block
            )
            guard status == noErr, let block else { throw ConversionError.unsupportedAudio("block \(status)") }
            status = bytes.withUnsafeBytes {
                CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
            }
            guard status == noErr else { throw ConversionError.unsupportedAudio("copy \(status)") }
            var sample: CMSampleBuffer?
            status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block, formatDescription: formatDescription, sampleCount: frames,
                presentationTimeStamp: CMTime(value: CMTimeValue(startFrame), timescale: CMTimeScale(format.sampleRate)),
                packetDescriptions: nil, sampleBufferOut: &sample
            )
            guard status == noErr, let sample else { throw ConversionError.unsupportedAudio("sample \(status)") }
            buffers.append(sample)
            startFrame += frames
        }
        return buffers
    }
}

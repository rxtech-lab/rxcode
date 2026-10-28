import Foundation
import Testing
@testable import RxCodeCore

struct FilePreviewFormatTests {
    @Test func renderedSourceFormats() {
        for name in ["README.md", "notes.MARKDOWN", "notes.mdown"] {
            #expect(FilePreviewFormat(fileName: name) == .markdown)
        }
        for name in ["index.html", "index.HTM", "page.xhtml"] {
            #expect(FilePreviewFormat(fileName: name) == .html)
        }
        #expect(FilePreviewFormat(fileName: "image.svg").canReadSource(fileName: "image.svg"))
    }

    @Test func mediaAndOfficeBypassSourceLoading() {
        for ext in ["mp4", "mov", "mp3", "m4a", "wav", "ppt", "pptx", "doc", "docx", "xls", "xlsx", "pdf", "png"] {
            let name = "sample.\(ext)"
            let format = FilePreviewFormat(fileName: name)
            #expect(format == .native, "\(ext) should use Quick Look")
            #expect(!format.canReadSource(fileName: name))
        }
    }

    @Test func sourceAndUnknownFilesRemainReadable() {
        for name in ["app.swift", "app.ts", "config.yaml", ".env", "Dockerfile", "file.unknownextension"] {
            #expect(FilePreviewFormat(fileName: name) == .text)
        }
    }

    @Test func binaryIsNeverEditableText() {
        #expect(FilePreviewFormat.decodeSource(Data([0, 1, 2])) == nil)
        #expect(FilePreviewFormat.decodeSource(Data([0xFF, 0x12])) == nil)
        #expect(FilePreviewFormat.decodeSource(Data("Hello 🌍".utf8)) == "Hello 🌍")
        #expect(FilePreviewFormat.decodeSource(Data()) == "")
        #expect(FilePreviewFormat.decodeSource(Data([0xFF, 0xFE, 0x48, 0, 0x69, 0])) == "Hi")
    }
}

import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import RxCodeCore

@Suite("Briefing notifications")
struct BriefingNotificationTests {

    // MARK: - Body images

    private let base = URL(fileURLWithPath: "/tmp/briefings/B1", isDirectory: true)

    @Test("Local Markdown and HTML images are found in order; remote and data sources are ignored")
    func findsLocalImages() {
        let body = """
        # Report
        ![Chart](images/chart.png)
        ![Remote](https://example.com/a.png)
        <img alt="Logo" src="images/logo.png" width="40">
        ![Inline](data:image/png;base64,AAAA)
        ![Absolute](</Users/me/shot one.png> "Screenshot")
        """
        let refs = NotificationBodyImages.references(in: body, format: .markdown, baseURL: base, fileExists: { _ in true })
        #expect(refs.map(\.source) == ["images/chart.png", "images/logo.png", "/Users/me/shot one.png"])
        #expect(refs[0].fileURL.path == "/tmp/briefings/B1/images/chart.png")
        #expect(refs[1].altText == "Logo")
        #expect(refs[2].altText == "Absolute")
    }

    @Test("Missing files and Markdown syntax in HTML briefings are skipped")
    func skipsMissingFiles() {
        let body = "![A](images/a.png) <img src='images/b.png'>"
        let markdown = NotificationBodyImages.references(
            in: body, format: .markdown, baseURL: base, fileExists: { $0.lastPathComponent == "b.png" }
        )
        #expect(markdown.map(\.source) == ["images/b.png"])
        let html = NotificationBodyImages.references(in: body, format: .html, baseURL: base, fileExists: { _ in true })
        #expect(html.map(\.source) == ["images/b.png"])
    }

    @Test("Uploaded images become attachment placeholders and failed ones fall back to alt text")
    func replacesReferences() {
        let body = "Intro\n![Chart](images/chart.png)\n![Gone](images/gone.png)\nEnd"
        let refs = NotificationBodyImages.references(in: body, format: .markdown, baseURL: base, fileExists: { _ in true })
        let chartURL = base.appendingPathComponent("images/chart.png").standardizedFileURL
        let result = NotificationBodyImages.replacing(refs, in: body, attachmentIds: [chartURL: "att_1"])
        #expect(result == "Intro\n{{attachment:att_1}}\nGone\nEnd")
    }

    @Test("Only file-like sources resolve to local URLs")
    func resolvesSources() {
        #expect(NotificationBodyImages.resolve("file:///tmp/x.png", baseURL: base)?.path == "/tmp/x.png")
        #expect(NotificationBodyImages.resolve("images/a%20b.png", baseURL: base)?.path == "/tmp/briefings/B1/images/a b.png")
        #expect(NotificationBodyImages.resolve("http://x/y.png", baseURL: base) == nil)
        #expect(NotificationBodyImages.resolve("cid:abc", baseURL: base) == nil)
        #expect(NotificationBodyImages.resolve("#anchor", baseURL: base) == nil)
    }

    // MARK: - Decision

    @Test("Decision prompt carries the project configuration and source context")
    func promptIncludesContext() {
        let prompt = BriefingNotificationDecision.prompt(for: .init(
            briefingTitle: "Nightly CI",
            briefingFormat: .markdown,
            briefingContent: "All green",
            imageCount: 2,
            projectName: "RxCode",
            gitHubRepo: "rxtech-lab/rxcode",
            mode: .automatic,
            recipient: "me@example.com",
            sourcePrompt: "Summarize CI and email me",
            scheduledTaskName: "Nightly report",
            scheduledTaskSchedule: "0 9 * * *",
            notificationsAlreadySent: ["CI done"]
        ))
        #expect(prompt.contains("Project: RxCode"))
        #expect(prompt.contains("GitHub repository: rxtech-lab/rxcode"))
        #expect(prompt.contains("Recipient: me@example.com"))
        #expect(prompt.contains("scheduled task \"Nightly report\" (cron: 0 9 * * *)"))
        #expect(prompt.contains("\"CI done\""))
        #expect(prompt.contains("Summarize CI and email me"))
        #expect(prompt.contains("Local images: 2"))
    }

    @Test("Decision replies are parsed from fenced or bare JSON")
    func parsesDecision() {
        let fenced = BriefingNotificationDecision.parse("""
        ```json
        {"send": true, "subject": "Nightly CI passed", "reason": "Scheduled report"}
        ```
        """)
        #expect(fenced == BriefingNotificationDecision(shouldSend: true, subject: "Nightly CI passed", reason: "Scheduled report"))

        let bare = BriefingNotificationDecision.parse(#"Sure: {"send": "no", "subject": "", "reason": "Draft"}"#)
        #expect(bare == BriefingNotificationDecision(shouldSend: false, subject: nil, reason: "Draft"))

        #expect(BriefingNotificationDecision.parse("I think yes") == nil)
        #expect(BriefingNotificationDecision.parse(#"{"subject": "x"}"#) == nil)
    }

    // MARK: - Settings & store

    @Test("Project overrides win over the default mode, and the master switch turns everything off")
    func settingsModes() {
        let project = UUID()
        var settings = BriefingNotificationSettings(defaultMode: .automatic, projectModes: [project: .never])
        #expect(settings.mode(for: project) == .never)
        #expect(settings.mode(for: UUID()) == .automatic)
        #expect(settings.mode(for: nil) == .automatic)
        settings.isEnabled = false
        #expect(settings.mode(for: nil) == .never)
    }

    @Test("Settings and history round-trip through disk")
    func storeRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("NotificationStore-\(UUID().uuidString)")
        let store = NotificationStore(baseURL: dir)
        #expect(await store.settings() == BriefingNotificationSettings())

        let project = UUID()
        let settings = BriefingNotificationSettings(isEnabled: true, recipient: "a@b.co", defaultMode: .always, projectModes: [project: .never])
        try await store.saveSettings(settings)

        let briefing = UUID()
        let publishedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.append(NotificationRecord(
            source: .agent, status: .sent, subject: "Hi", sessionKey: "s1", createdAt: publishedAt.addingTimeInterval(5)
        ))
        try await store.append(NotificationRecord(
            source: .briefing, status: .skipped, subject: "Weekly", briefingId: briefing, createdAt: publishedAt
        ))

        let reopened = NotificationStore(baseURL: dir)
        #expect(await reopened.settings() == settings)
        let history = await reopened.history()
        #expect(history.map(\.subject) == ["Weekly", "Hi"])
        #expect(await reopened.hasSent(briefingId: briefing) == false)
        #expect(await reopened.hasSent(fromSessions: ["s1"], since: publishedAt))
        #expect(await reopened.hasSent(fromSessions: ["s1"], since: publishedAt.addingTimeInterval(10)) == false)
        #expect(await reopened.hasSent(fromSessions: ["other"], since: publishedAt) == false)
    }

    @Test("History is capped")
    func historyCap() async throws {
        let store = NotificationStore(baseURL: FileManager.default.temporaryDirectory.appendingPathComponent("NotificationStore-\(UUID().uuidString)"))
        for index in 0..<(NotificationStore.historyLimit + 3) {
            try await store.append(NotificationRecord(source: .agent, status: .sent, subject: "\(index)"))
        }
        let history = await store.history()
        #expect(history.count == NotificationStore.historyLimit)
        #expect(history.first?.subject == "\(NotificationStore.historyLimit + 2)")
    }

    @Test("Allowed recipients are the account email plus verified trusted emails")
    func allowedRecipients() {
        let list = TrustedEmailList(accountEmail: "me@x.co", items: [
            TrustedEmail(id: "1", email: "team@x.co", status: .verified),
            TrustedEmail(id: "2", email: "wait@x.co", status: .pending),
            TrustedEmail(id: "3", email: "ME@x.co", status: .verified),
        ])
        #expect(list.allowedRecipients == ["me@x.co", "team@x.co"])
    }

    // MARK: - WebP

    @Test("Images are re-encoded as WebP and scaled down")
    func encodesWebP() throws {
        let width = 64, height = 32
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())

        let png = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))

        let webp = try #require(WebPEncoder.encode(imageData: png as Data, maxPixelSize: 32))
        #expect(WebPEncoder.isWebP(webp))
        let decoded = try #require(CGImageSourceCreateWithData(webp as CFData, nil).flatMap {
            CGImageSourceCreateImageAtIndex($0, 0, nil)
        })
        #expect(decoded.width == 32)
        #expect(decoded.height == 16)
        #expect(WebPEncoder.encode(imageData: Data("not an image".utf8)) == nil)
    }
}

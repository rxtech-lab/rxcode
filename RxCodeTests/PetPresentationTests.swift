import AppKit
import SwiftUI
import RxCodeChatKit
import RxCodeCore
import Testing
@testable import RxCode

struct PetPresentationTests {
    @Test("Pet presentation follows its moving parent without replacing its window or content")
    @MainActor
    func persistentPresentationPanel() async throws {
        let parent = NSPanel(contentRect: CGRect(x: 200, y: 200, width: 200, height: 200),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let anchor = PetPresentationAnchorView(frame: CGRect(x: 50, y: 50, width: 100, height: 100))
        parent.contentView = anchor
        defer { anchor.tearDown(); parent.orderOut(nil) }
        let id = UUID()
        anchor.update(id: id, content: AnyView(Text("Retained content").frame(width: 240, height: 160)))
        anchor.positionPanel()
        let panel = try #require(anchor.presentationPanel)
        let host = try #require(panel.contentView)
        #expect(panel.parent === parent)
        #expect(!panel.hidesOnDeactivate)
        let before = panel.frame
        #expect(before.size == CGSize(width: 240, height: 160))
        // Dragging and automatic travel both move the parent's native frame.
        parent.setFrameOrigin(CGPoint(x: 350, y: 350))
        try await Task.sleep(for: .milliseconds(50))
        #expect(anchor.presentationPanel === panel)
        #expect(panel.contentView === host)
        #expect(panel.frame.origin != before.origin)
        #expect(panel.frame.size == before.size)
        panel.cancelOperation(nil)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        #expect(anchor.presentationPanel === panel)
        #expect(panel.parent === parent)
        // Only the explicit presentation-state close tears down the native surface.
        anchor.update(id: nil, content: AnyView(EmptyView()))
        #expect(anchor.presentationPanel == nil)
        #expect(!(parent.childWindows ?? []).contains(panel))
    }

    @Test("Pet presentation stays on screen at edges and across displays")
    @MainActor
    func presentationScreenEdges() {
        for visible in [CGRect(x: 0, y: 0, width: 1200, height: 800),
                        CGRect(x: -1200, y: 100, width: 1200, height: 800)] {
            for point in [visible.origin, CGPoint(x: visible.maxX - 100, y: visible.maxY - 100)] {
                let frame = PetPresentationAnchorView.presentationFrame(
                    anchor: CGRect(origin: point, size: CGSize(width: 100, height: 100)),
                    size: CGSize(width: 420, height: 360), visible: visible)
                #expect(visible.contains(frame))
            }
        }
    }

    @Test("Pet UI defaults to the caption card and supports an explicit popover")
    @MainActor
    func captionRouting() {
        let spec = JSONUISpec(root: "text", elements: ["text": .init(type: "Text", props: ["text": "Hello"])])
        for style: String? in [nil, "bubble", "popover"] {
            let dialog = AgentUIDialog(sessionKey: "pet-test", title: nil, spec: spec, petPresentation: style)
            #expect(dialog.usesPetCaption == (style != "popover"))
        }
        let threadView = AgentUIDialog(sessionKey: "thread-test", title: nil, spec: spec)
        #expect(!threadView.usesPetCaption)
    }

    @Test("Interactive and oversized UI uses a popover even when bubble is requested")
    @MainActor
    func captionLimits() {
        for type in ["Button", "TextField", "Picker", "Slider", "Toggle", "TextEditor", "Link", "Table", "Image", "Tabs"] {
            let spec = JSONUISpec(root: "item", elements: ["item": .init(type: type)])
            let dialog = AgentUIDialog(sessionKey: "pet-test", title: nil, spec: spec, petPresentation: "bubble")
            #expect(!dialog.usesPetCaption)
        }
        for count in [1, 5, 6] {
            let spec = JSONUISpec(root: "text", elements: ["text": .init(type: "Text", props: [
                "text": .string(Array(repeating: "Row", count: count).joined(separator: "\n"))
            ])])
            let dialog = AgentUIDialog(sessionKey: "pet-test", title: nil, spec: spec)
            #expect(dialog.usesPetCaption == (count <= 5))
        }
    }

    @Test("A short weather summary wraps inside the caption instead of opening a popover")
    @MainActor
    func wrappedWeatherCaption() {
        let dialog = AgentUIDialog(sessionKey: "pet-test", title: nil,
            spec: JSONUISpec(root: "text", elements: ["text": .init(type: "Text", props: [
                "text": "香港明天下午：多云，短暂阳光，稍后有雨，记得带伞。"
            ])]))
        let controller = PetController()
        let host = NSHostingView(rootView: PetCaptionUIView(dialog: dialog, controller: controller))
        let size = host.fittingSize
        #expect(dialog.usesPetCaption)
        #expect(size.width <= 237)
        #expect(size.height > 34) // More than one text row plus vertical padding.
        #expect(size.height <= 106)
    }

    @Test("A one-line inline UI card uses its content height")
    @MainActor
    func shortCaptionCardFitsContent() {
        let dialog = AgentUIDialog(sessionKey: "pet-test", title: nil,
            spec: JSONUISpec(root: "text", elements: ["text": .init(type: "Text", props: ["text": "☀️ 26°C"])]))
        let host = NSHostingView(rootView: PetCaptionUIView(dialog: dialog, controller: PetController()))
        host.frame = NSRect(x: 0, y: 0, width: 236, height: 300)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height < 45)
    }

    @Test("Caption overflow promotes the retained view without losing its identity")
    @MainActor
    func captionOverflow() {
        let state = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        let dialog = AgentUIDialog(sessionKey: "pet-test", title: nil,
            spec: JSONUISpec(root: "text", elements: ["text": .init(type: "Text", props: ["text": "Long text"])]))
        state.agentPrompts.dialogs.append(dialog)
        state.agentPrompts.views.append(dialog)
        state.expandPetCaptionToPopover(id: dialog.id)
        #expect(state.agentPrompts.dialogs.first?.petPresentation == "popover")
        #expect(state.agentPrompts.views.first?.petPresentation == "popover")
        #expect(state.agentPrompts.dialogs.first?.id == dialog.id)
    }

    @Test("New pet UI requests never reopen the companion window")
    @MainActor
    func dialogsDoNotReopenCompanion() {
        let state = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        let controller = PetController()
        var openedWindows: [String] = []
        controller.openWindowAction = { openedWindows.append($0) }
        for index in 0..<2 {
            state.agentPrompts.dialogs.append(AgentUIDialog(
                sessionKey: "pet-test", title: "View \(index)",
                spec: JSONUISpec(root: "text", elements: ["text": .init(type: "Text", props: ["text": "Hello"])])))
            controller.observeIncomingPetPrompts(in: state)
        }
        #expect(openedWindows.isEmpty)
    }

    @Test("Pet UI uses the pet surface even without pet_presentation", arguments: ["default", "inline", "dialog"])
    @MainActor
    func petUIDefaultRouting(presentation: String) async throws {
        let state = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        let controller = PetController.shared
        let wasEnabled = controller.configuration.isEnabled
        controller.configuration.isEnabled = false
        defer { controller.configuration.isEnabled = wasEnabled }
        var arguments: [String: JSONValue] = ["spec": .object([
            "root": .string("text"), "elements": .object([
                "text": .object(["type": .string("Text"), "props": .object(["text": .string("Hello")])])
            ])
        ])]
        if presentation != "default" { arguments["presentation"] = .string(presentation) }
        do {
            _ = try await state.handleShowUI(arguments: .object(arguments), sessionKey: "pet-test")
            Issue.record("A disabled pet must reject the request instead of silently rendering inline or opening a sheet.")
        } catch {
            #expect(error.localizedDescription.contains("Enable the desktop pet"))
        }
        #expect(state.agentPrompts.dialogs.isEmpty)
        #expect(state.agentPrompts.views.isEmpty)
    }

    @Test("Pet images survive collapse, new content and transient tool expiration")
    @MainActor
    func retainedImageLifecycle() {
        let controller = PetController()
        let presentation = controller.presentation
        let first = PetImagePresentation(image: NSImage(size: NSSize(width: 8, height: 8)), title: "First", style: "popover")
        let second = PetImagePresentation(image: first.image, title: "Second", style: "bubble")
        presentation.retainImage(first)
        presentation.collapse(first.id)
        #expect(presentation.expandedID == nil)
        #expect(presentation.images.map(\.id) == [first.id])
        presentation.retainImage(second)
        presentation.collapse(first.id) // A late dismissal cannot collapse the newly opened surface.
        #expect(presentation.expandedID == second.id)
        controller.toolActivity.removeExpiredCalls(now: .distantFuture)
        #expect(presentation.images.count == 2)
        presentation.expand(first.id)
        presentation.removeImage(first.id)
        #expect(presentation.expandedID == nil)
        #expect(presentation.images.map(\.id) == [second.id])
    }

    @Test("Pet dialogs collapse and reopen with retained interaction state; removal clears them")
    @MainActor
    func retainedDialogLifecycle() {
        let state = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        let dialog = AgentUIDialog(sessionKey: "pet-test", title: "Form",
            spec: JSONUISpec(root: "text", elements: ["text": .init(type: "Text", props: ["text": "Hello"])]))
        state.agentPrompts.views.append(dialog)
        state.agentPrompts.dialogs.append(dialog)
        let presentation = PetController.shared.presentation
        let interaction = presentation.interaction(for: dialog)
        presentation.expand(dialog.id)
        state.dismissAgentUIDialog(id: dialog.id)
        #expect(state.agentPrompts.dialogs.contains { $0.id == dialog.id })
        #expect(presentation.expandedID == nil)
        state.openAgentUIView(id: dialog.id)
        #expect(presentation.expandedID == dialog.id)
        #expect(presentation.interaction(for: dialog) === interaction)
        state.removeAgentUIView(id: dialog.id)
        #expect(!state.agentPrompts.dialogs.contains { $0.id == dialog.id })
        #expect(!state.agentPrompts.views.contains { $0.id == dialog.id })
        #expect(presentation.expandedID == nil)
        #expect(presentation.interaction(for: dialog) !== interaction)
        presentation.removeDialog(dialog.id)
    }

    @Test("Closing status clears bindings and invalidates pending rollback until an explicit new set")
    @MainActor
    func dismissStatusLifecycle() async {
        let controller = PetController()
        let presentation = controller.presentation
        let spec = JSONUISpec(root: "status", elements: ["status": .init(type: "Text", props: [
            "text": .object(["$ide": .string("running_sessions")])
        ])])
        let image = PetImagePresentation(image: NSImage(size: NSSize(width: 8, height: 8)), title: "Kept", style: "popover")
        presentation.retainImage(image)
        let revision = presentation.installWidget(spec)
        presentation.visibleWidgetRevision = revision
        presentation.clearWidget()
        #expect(presentation.widget == nil)
        #expect(presentation.visibleWidgetRevision == nil)
        #expect(presentation.widgetRevision != revision)
        _ = PetWidgetSchema.indicatorText(spec, runningTasks: 0, runningSessions: 5)
        #expect(presentation.widget == nil)
        do {
            _ = try await presentation.setWidget(.object(["operation": "update", "elements": .object([:])]))
            Issue.record("Updates must not reopen a user-dismissed status card.")
        } catch { #expect(presentation.widget == nil) }
        let nextRevision = presentation.installWidget(spec)
        #expect(presentation.widget == spec)
        #expect(nextRevision != revision)
        #expect(presentation.images.map(\.id) == [image.id])
        #expect(presentation.expandedID == image.id)
    }

    @Test("Status Text and Badge have genuinely small intrinsic surfaces; sentences wrap")
    @MainActor
    func statusIntrinsicSize() {
        let controller = PetController()
        for type in ["Text", "Badge"] {
            controller.presentation.widget = JSONUISpec(root: "status", elements: [
                "status": .init(type: type, props: ["text": "🌱"])
            ])
            let host = NSHostingView(rootView: PetStatusWidgetView(controller: controller))
            let size = host.fittingSize
            #expect(size.width > 0 && size.width < 70)
            #expect(size.height > 0 && size.height < 50)
        }
        controller.presentation.widget = JSONUISpec(root: "status", elements: [
            "status": .init(type: "Text", props: ["text": "Checking the latest build while you work."])
        ])
        let sentence = NSHostingView(rootView: PetStatusWidgetView(controller: controller)).fittingSize
        #expect(sentence.width <= 220)
        #expect(sentence.height < 100)
        controller.panelController.updateStatusSize(CGSize(width: 24, height: 19))
        #expect(controller.panelController.statusSize == NSSize(width: 24, height: 19))
    }

}

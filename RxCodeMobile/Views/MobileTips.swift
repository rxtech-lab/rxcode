import SwiftUI
import TipKit

enum MobileTips {
    struct PairingTip: Tip {
        var title: Text {
            Text("Pair with your Mac")
        }

        var message: Text? {
            Text("Scan the QR code from RxCode Settings on your Mac to control threads and approvals from this device.")
        }

        var image: Image? {
            Image(systemName: "qrcode.viewfinder")
        }

        var options: [any TipOption] {
            Tips.MaxDisplayCount(1)
        }
    }

    struct BriefingTip: Tip {
        var title: Text {
            Text("Review project briefings")
        }

        var message: Text? {
            Text("Branch briefings collect recent thread summaries from your Mac into a quick mobile status view.")
        }

        var image: Image? {
            Image(systemName: "doc.text")
        }

        var options: [any TipOption] {
            Tips.MaxDisplayCount(1)
        }
    }

    struct SearchTip: Tip {
        var title: Text {
            Text("Search projects and threads")
        }

        var message: Text? {
            Text("Use mobile search to find synced projects, thread titles, and desktop search hits.")
        }

        var image: Image? {
            Image(systemName: "magnifyingglass")
        }

        var options: [any TipOption] {
            Tips.MaxDisplayCount(1)
        }
    }

    struct RemoteProjectTip: Tip {
        var title: Text {
            Text("Add a project from your Mac")
        }

        var message: Text? {
            Text("Pick a desktop folder remotely, then start or continue its threads from mobile.")
        }

        var image: Image? {
            Image(systemName: "folder.badge.plus")
        }

        var options: [any TipOption] {
            Tips.MaxDisplayCount(1)
        }
    }

    struct AgentSelectionTip: Tip {
        var title: Text {
            Text("Choose the thread agent")
        }

        var message: Text? {
            Text("Start a mobile-created thread with Claude Code, Codex, or an ACP agent synced from your Mac.")
        }

        var image: Image? {
            Image(systemName: "sparkles")
        }

        var options: [any TipOption] {
            Tips.MaxDisplayCount(1)
        }
    }

    struct PlanModeTip: Tip {
        var title: Text {
            Text("Start with a plan")
        }

        var message: Text? {
            Text("Enable Plan before sending a new thread so the desktop agent drafts a read-only plan first.")
        }

        var image: Image? {
            Image(systemName: "checklist")
        }

        var options: [any TipOption] {
            Tips.MaxDisplayCount(1)
        }
    }

    struct SummarizationTip: Tip {
        var title: Text {
            Text("Control desktop summaries")
        }

        var message: Text? {
            Text("Change the summarization provider from mobile; API keys and endpoint secrets stay on the Mac.")
        }

        var image: Image? {
            Image(systemName: "text.badge.checkmark")
        }

        var options: [any TipOption] {
            Tips.MaxDisplayCount(1)
        }
    }
}

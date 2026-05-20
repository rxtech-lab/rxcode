import SwiftUI
import TipKit

enum RxCodeTips {
    struct AgentSelectionTip: Tip {
        var title: Text {
            Text("Choose the agent for this thread")
        }

        var message: Text? {
            Text("Switch between Claude Code, Codex, and installed ACP agents without changing the global default.")
        }

        var image: Image? {
            Image(systemName: "sparkles")
        }

        var options: [any TipOption] {
            Tips.MaxDisplayCount(1)
        }
    }

    struct MCPTip: Tip {
        var title: Text {
            Text("Add tools with MCP")
        }

        var message: Text? {
            Text("Manage MCP servers once in RxCode, then enable or disable them globally or per project.")
        }

        var image: Image? {
            Image(systemName: "puzzlepiece.extension")
        }

        var options: [any TipOption] {
            Tips.MaxDisplayCount(1)
        }
    }

    struct ACPTip: Tip {
        var title: Text {
            Text("Install ACP agents")
        }

        var message: Text? {
            Text("Use the registry to add Agent Client Protocol tools, then pick them from the thread model menu.")
        }

        var image: Image? {
            Image(systemName: "link.circle")
        }

        var options: [any TipOption] {
            Tips.MaxDisplayCount(1)
        }
    }

    struct MobileConnectionTip: Tip {
        var title: Text {
            Text("Connect the mobile companion")
        }

        var message: Text? {
            Text("Pair an iPhone or iPad to review threads, answer approvals, and send messages to your desktop agent.")
        }

        var image: Image? {
            Image(systemName: "iphone.gen3")
        }

        var options: [any TipOption] {
            Tips.MaxDisplayCount(1)
        }
    }

    struct SummarizationModelTip: Tip {
        var title: Text {
            Text("Set the summarization model")
        }

        var message: Text? {
            Text("Keep summaries on the thread model, or route titles and briefings through an OpenAI-compatible endpoint.")
        }

        var image: Image? {
            Image(systemName: "text.badge.checkmark")
        }

        var options: [any TipOption] {
            Tips.MaxDisplayCount(1)
        }
    }

    struct BriefingTip: Tip {
        var title: Text {
            Text("Open the branch briefing")
        }

        var message: Text? {
            Text("Briefing rolls recent thread summaries into a branch-focused project update.")
        }

        var image: Image? {
            Image(systemName: "text.page")
        }

        var options: [any TipOption] {
            Tips.MaxDisplayCount(1)
        }
    }

    struct GlobalSearchTip: Tip {
        var title: Text {
            Text("Search every thread")
        }

        var message: Text? {
            Text("Press Command-K or use the toolbar search button to find past work across projects.")
        }

        var image: Image? {
            Image(systemName: "magnifyingglass")
        }

        var options: [any TipOption] {
            Tips.MaxDisplayCount(1)
        }
    }
}

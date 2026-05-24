import Foundation
import Testing
@testable import RxCodeCore

@Suite("Localized enum labels")
struct LocalizedEnumLabelTests {
    @Test("Permission mode labels localize through resource helpers")
    func permissionModeLabels() {
        #expect(PermissionMode.default.displayNameText == String(localized: PermissionMode.default.displayName))
        #expect(PermissionMode.acceptEdits.displayNameText == "Accept Edits")
        #expect(PermissionMode.bypassPermissions.displayNameText == "Bypass")
    }

    @Test("Agent provider labels keep localized text helpers for payload strings")
    func agentProviderLabels() {
        #expect(AgentProvider.claudeCode.displayNameText == String(localized: AgentProvider.claudeCode.displayName))
        #expect(AgentProvider.codex.displayNameText == "Codex")
        #expect(AgentProvider.acp.displayNameText == "ACP")
    }

    @Test("Inspector labels do not rely on persisted raw values for display")
    func inspectorLabels() {
        #expect(InspectorTab.memo.titleText == String(localized: InspectorTab.memo.title))
        #expect(InspectorReviewTab.thisThread.titleText == "This thread")
        #expect(InspectorMode.inspector.titleText == "Inspector")
    }

    @Test("MCP enum labels expose localized resources and text fallbacks")
    func mcpLabels() {
        #expect(MCPScope.user.displayNameText == String(localized: MCPScope.user.displayName))
        #expect(MCPScope.local.subtitleText == "This project, this machine only")
        #expect(MCPProjectOverride.enabled.displayNameText == "On")
        #expect(MCPTransport.http.displayNameText == "HTTP")
    }

    @Test("Theme labels expose localized resources and text fallbacks")
    func themeLabels() {
        #expect(AppTheme.claude.displayNameText == String(localized: AppTheme.claude.displayName))
        #expect(AppTheme.ocean.displayNameText == "Ocean (Blue)")
    }
}

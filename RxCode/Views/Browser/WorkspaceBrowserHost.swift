import RxCodeCore
import SwiftUI

/// Owns the window's browser tabs and preview source. Workspace windows show
/// both in the right inspector; single-purpose chat and route windows have no
/// inspector, so they present the browser in a sheet instead.
struct WorkspaceBrowserHost: ViewModifier {
    let appState: AppState
    let windowState: WindowState
    let opensLinksInSheet: Bool
    @State private var design: WorkspaceDesignSession
    @State private var showsSheet = false

    init(appState: AppState, windowState: WindowState, browserSheetID: UUID? = nil) {
        self.appState = appState
        self.windowState = windowState
        opensLinksInSheet = browserSheetID != nil
        _design = State(initialValue: WorkspaceDesignSession(window: windowState, defaults: appState.workspaceDefaults,
                                                             browserSheetID: browserSheetID))
    }

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, workspaceOpenURLAction(
                appState: appState,
                windowState: windowState,
                openDocument: opensLinksInSheet ? nil : { url in
                    revealInspector(.preview)
                    Task { await design.open(.document(url)) }
                },
                openWebPage: { url in
                    revealBrowser().open(url)
                }
            ))
            .sheet(isPresented: $showsSheet) {
                NavigationStack {
                    WorkspaceBrowserView()
                        .navigationTitle("Browser")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showsSheet = false }
                            }
                        }
                }
                .frame(minWidth: 560, idealWidth: 900, minHeight: 420, idealHeight: 680)
            }
            .environment(design.browser)
            .environment(design)
            .onAppear {
                design.revealBrowser = revealBrowser
                appState.designSessions[ObjectIdentifier(windowState)] = design
            }
            .onDisappear {
                if appState.designSessions[ObjectIdentifier(windowState)] === design {
                    appState.designSessions.removeValue(forKey: ObjectIdentifier(windowState))
                }
                design.revealBrowser = nil
            }
    }

    private func revealBrowser() -> WorkspaceBrowser {
        if opensLinksInSheet {
            showsSheet = true
            return design.browser
        }
        revealInspector(.browser)
        return design.inspectorBrowser
    }

    private func revealInspector(_ mode: InspectorMode) {
        windowState.inspectorMode = mode
        appState.showRightSidebar = true
    }
}

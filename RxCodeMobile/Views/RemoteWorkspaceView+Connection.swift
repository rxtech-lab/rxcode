import os.log
import RxCodeCore
import RxCodeSync
import SwiftUI

extension RemoteWorkspaceView {
    /// Whether the loading splash should be dismissed (data loaded AND minimum time elapsed, but NOT timed out)
    private var shouldShowContent: Bool {
        hasShownWorkspace || isInitialSyncComplete
    }

    private var isResumingWorkspace: Bool {
        hasShownWorkspace && state.isResumingFromBackground
    }

    private var isInitialSyncComplete: Bool {
        state.isDesktopTaskSyncReady && minimumLoadingTimeElapsed && !connectionTimedOut
    }

    var paired: some View {
        ZStack {
            // Mount the desktop workspace only when it is reachable. Hidden
            // task views must not issue requests or present alerts behind the cloud sheet.
            if shouldShowContent {
                mainContent
                    .overlay(alignment: .top) {
                        if showReconnectOverlay {
                            MobileReconnectOverlay(
                                desktopName: state.activePairedDesktop?.displayName,
                                isUnavailable: state.desktopTaskUnavailable,
                                isRetrying: isRetryingConnection,
                                onRetry: {
                                    MobileHaptics.buttonTap()
                                    Task { await retryConnection() }
                                }
                            )
                            .padding(.top, 6)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .animation(.spring(duration: 0.3), value: showReconnectOverlay)
            }

            // Coming back from the background: the mirror may be stale even if
            // the socket reports connected, so block the workspace (kept
            // mounted underneath) until a fresh snapshot lands.
            if isResumingWorkspace {
                SyncLoadingView(
                    isTimedOut: resumeTimedOut && !isRetryingConnection,
                    pairedDesktops: state.pairedDesktops,
                    activeDesktopID: state.activePairedDesktop?.id,
                    onRetry: {
                        MobileHaptics.buttonTap()
                        resumeTimedOut = false
                        Task { await retryConnection() }
                    },
                    onSelectDesktop: { desktop in
                        MobileHaptics.buttonTap()
                        resumeTimedOut = false
                        Task {
                            await state.switchPairedDesktop(desktop)
                            await retryConnection()
                        }
                    }
                )
                .background(Color(UIColor.systemBackground).ignoresSafeArea())
                .overlay(alignment: .topTrailing) {
                    connectionScreenCloseButton
                }
                .accessibilityIdentifier("resume-reconnect-page")
                .transition(.opacity)
                .zIndex(2)
            }

            // Loading splash - shown until first snapshot AND minimum 2 seconds
            if !shouldShowContent {
                SyncLoadingView(
                    isTimedOut: !isRetryingConnection && (connectionTimedOut || state.desktopTaskUnavailable),
                    pairedDesktops: state.pairedDesktops,
                    activeDesktopID: state.activePairedDesktop?.id,
                    onRetry: {
                        connectionTimedOut = false
                        Task {
                            await retryConnection()
                        }
                    },
                    onSelectDesktop: { desktop in
                        connectionTimedOut = false
                        minimumLoadingTimeElapsed = false
                        Task {
                            await state.switchPairedDesktop(desktop)
                            await retryConnection()
                        }
                    }
                )
                .overlay(alignment: .topTrailing) {
                    connectionScreenCloseButton
                }
                .transition(.splashTransition)
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: shouldShowContent)
        .animation(.easeInOut(duration: 0.3), value: isResumingWorkspace)
        .onChange(of: isResumingWorkspace) { wasResuming, resuming in
            if wasResuming, !resuming, scenePhase == .active {
                MobileHaptics.connected()
            }
        }
        .task(id: isResumingWorkspace && scenePhase == .active) {
            // Time the resume only while in the foreground: the clock keeps
            // running during suspension and would otherwise fire immediately.
            resumeTimedOut = false
            guard isResumingWorkspace, scenePhase == .active else { return }
            do {
                try await Task.sleep(for: .seconds(15))
            } catch {
                return
            }
            Self.logger.warning("Foreground resume timed out connection=\(String(describing: state.connectionState), privacy: .public) unavailable=\(state.desktopTaskUnavailable, privacy: .public)")
            MobileHaptics.connectionError()
            resumeTimedOut = true
        }
        .task {
            await initialLoad()
        }
        .onChange(of: state.isDesktopTaskSyncReady) { _, ready in
            Self.logger.info("Desktop sync ready changed: \(ready, privacy: .public) hasShownWorkspace=\(hasShownWorkspace, privacy: .public) connection=\(String(describing: state.connectionState), privacy: .public) unavailable=\(state.desktopTaskUnavailable, privacy: .public)")
            if ready {
                connectionTimedOut = false
            }
        }
        .onChange(of: isInitialSyncComplete) { _, complete in
            if complete, !hasShownWorkspace {
                Self.logger.info("Workspace shown; later reconnects keep it mounted")
                hasShownWorkspace = true
            }
        }
        .task(id: hasShownWorkspace && !state.isDesktopTaskSyncReady && !state.isResumingFromBackground) {
            // The full reconnecting page covers foreground resumes.
            guard hasShownWorkspace, !state.isDesktopTaskSyncReady, !state.isResumingFromBackground else {
                if showReconnectOverlay {
                    Self.logger.info("Reconnect overlay hidden")
                }
                showReconnectOverlay = false
                return
            }
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                return
            }
            Self.logger.info("Reconnect overlay shown connection=\(String(describing: state.connectionState), privacy: .public) unavailable=\(state.desktopTaskUnavailable, privacy: .public)")
            showReconnectOverlay = true
        }
        .onChange(of: state.activeSessionID) { oldValue, newValue in
            // Subscribing acknowledges an existing navigation; only an ID
            // replacement needs to change the destination again.
            guard let oldValue, let newValue,
                  MobileDraftSessionID.isDraft(oldValue)
                    || state.resolveSessionID(oldValue) == newValue else { return }
            openActiveSession(newValue)
        }
        .onChange(of: state.pendingDeepLink) { _, _ in
            consumePendingDeepLink()
        }
        .onChange(of: state.hasReceivedInitialSnapshot) { oldValue, newValue in
            // Reset states when snapshot state resets (e.g., switching paired desktops)
            if oldValue && !newValue {
                Self.logger.info("Desktop mirror cleared; showing sync splash again")
                hasShownWorkspace = false
                showReconnectOverlay = false
                minimumLoadingTimeElapsed = false
                connectionTimedOut = false
                Task {
                    await initialLoad()
                }
            }
        }
    }

    /// Leaves the remote workspace from the connecting / reconnecting pages
    /// so the user can return to Tasks instead of waiting on the Mac.
    @ViewBuilder
    private var connectionScreenCloseButton: some View {
        if let closeRemoteWorkspace {
            Button {
                MobileHaptics.buttonTap()
                closeRemoteWorkspace()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel("Close")
            .accessibilityIdentifier("close-connection-screen")
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .buttonBorderShape(.circle)
            .frame(minWidth: 44, minHeight: 44)
            .padding()
        }
    }

    /// Performs initial load with timeout handling
    func initialLoad() async {
        Self.logger.info("initialLoad started, current hasReceivedInitialSnapshot: \(state.hasReceivedInitialSnapshot)")

        let clock = ContinuousClock()
        let minimumLoadingDeadline = clock.now.advanced(by: .seconds(2))

        // Send the snapshot request (returns immediately, snapshot arrives async)
        consumePendingDeepLink()
        if !state.isDesktopTaskSyncReady {
            await state.refreshSnapshot()
        }

        // Wait for either snapshot to arrive or timeout
        let timeoutSeconds = 15
        let pollIntervalMs: UInt64 = 100
        let maxPolls = (timeoutSeconds * 1000) / Int(pollIntervalMs)

        var pollCount = 0
        while !state.isDesktopTaskSyncReady && pollCount < maxPolls {
            do { try await Task.sleep(for: .milliseconds(pollIntervalMs)) }
            catch { return }
            pollCount += 1
            if pollCount % 50 == 0 { // Log every 5 seconds
                Self.logger.debug("Still waiting for snapshot... polls=\(pollCount)/\(maxPolls)")
            }
        }

        // Count sync work toward the minimum splash duration. Fast or cached
        // connections still show the loading screen for at least two seconds.
        do { try await clock.sleep(until: minimumLoadingDeadline) }
        catch { return }

        let hasSnapshot = state.isDesktopTaskSyncReady
        Self.logger.info("Wait completed: hasSnapshot=\(hasSnapshot), polls=\(pollCount)/\(maxPolls)")

        guard !Task.isCancelled else { return }
        Self.logger.debug("PERFORMANCE: mobile initial sync wait polls=\(pollCount, privacy: .public) ready=\(hasSnapshot, privacy: .public)")

        if hasSnapshot {
            Self.logger.info("Connection successful - showing content")
            withAnimation {
                minimumLoadingTimeElapsed = true
            }
        } else {
            Self.logger.warning("Connection timed out after \(timeoutSeconds)s - showing timeout screen")
            withAnimation {
                connectionTimedOut = true
                minimumLoadingTimeElapsed = true
            }
        }
    }
}

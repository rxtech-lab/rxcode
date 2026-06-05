import Foundation

/// The serializable contract for the interactive "code review will start in
/// N seconds" countdown card. The Code Review hook inserts a `ToolCall` named
/// `ReviewCountdownCard.toolName` carrying these input keys; `ToolResultView`
/// special-cases that name to render `ReviewCountdownCardView` (a live timer
/// with Stop / Start-now buttons) instead of an ordinary tool card.
///
/// The card is a plain `ToolCall`, so it syncs to paired mobile devices for
/// free — mobile shows the live countdown read-only (the buttons only appear
/// when a `WindowState.reviewCountdownHandler` is installed, which the desktop
/// does and mobile does not).
public enum ReviewCountdownCard {
    /// Tool-call name that flags a card as the review countdown. Deliberately
    /// not prefixed `Hook:` so it doesn't fall into the generic hook-card path.
    public static let toolName = "Code Review Countdown"

    /// Input key: epoch seconds (Double) at which the review auto-starts.
    public static let startAtKey = "startAt"
    /// Input key: the parent thread's session key, used to route a button tap
    /// (or a context-menu "Stop Code Review") back to the right pending review.
    public static let parentSessionKey = "parentSessionKey"
}

/// What the user did on the countdown card (or its context-menu equivalent).
public enum ReviewCountdownAction: String, Codable, Sendable, Hashable {
    /// Skip the remaining delay and begin the review immediately.
    case startNow
    /// Cancel the pending review (and stop it if already running).
    case stop
}

/// Why an automatic code review was cancelled — drives the wording on the
/// finalized card so an explicit Stop isn't mislabeled as "a new message".
public enum ReviewCancelReason: String, Codable, Sendable, Hashable {
    /// The user sent a new follow-up message in the reviewed thread.
    case newMessage
    /// The user tapped "Stop Review" on the countdown card.
    case stopButton
    /// The user picked "Stop Code Review" from the thread context menu.
    case contextMenu
}

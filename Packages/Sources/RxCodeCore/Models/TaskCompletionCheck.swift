import Foundation

/// Thread labels stamped on the linked thread that verifies a finished task.
///
/// The check thread carries `inProgress` from the moment it is spawned until a
/// verdict lands, then flips to `verified` / `unverified`. The label is
/// persisted on the thread row, so it is shared by the app state that writes
/// it, the thread store that finalizes checks interrupted by a quit, and the
/// sidebar chip that reads it back.
public enum TaskCompletionCheckLabel {
    public static let inProgress = "Task Completion Check"
    public static let verified = "Task Completion Check: Verified"
    public static let unverified = "Task Completion Check: Unverified"
}

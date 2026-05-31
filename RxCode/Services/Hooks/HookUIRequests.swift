import Foundation
import RxCodeCore
import SwiftUI

/// A pending choice prompt driven by a hook. The view presents `choices` and
/// resumes `cont` with the picked id (or nil on cancel) via
/// `AppState.resolveHookChoice`.
struct HookChoiceRequest: Identifiable {
    let id = UUID()
    let title: LocalizedStringKey
    let choices: [HookChoice]
    let cont: CheckedContinuation<String?, Never>
}

/// A pending confirm/cancel prompt driven by a hook.
struct HookConfirmRequest: Identifiable {
    let id = UUID()
    let title: LocalizedStringKey
    let detail: String?
    let cont: CheckedContinuation<Bool, Never>
}

extension AppState {
    /// Resume a pending choice prompt and dismiss it. Safe to call once.
    func resolveHookChoice(_ id: String?) {
        guard let request = hookChoiceRequest else { return }
        hookChoiceRequest = nil
        request.cont.resume(returning: id)
    }

    /// Resume a pending confirmation prompt and dismiss it. Safe to call once.
    func resolveHookConfirm(_ ok: Bool) {
        guard let request = hookConfirmRequest else { return }
        hookConfirmRequest = nil
        request.cont.resume(returning: ok)
    }
}

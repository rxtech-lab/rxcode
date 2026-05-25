package app.rxlab.rxcode.ui.util

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.hapticfeedback.HapticFeedback
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalView

/**
 * Lightweight wrapper over the platform haptic feedback APIs so any Compose
 * screen can express intent ("light tap", "selection") without re-deriving the
 * underlying primitive each time. Mirrors the iOS app's
 * `UIImpactFeedbackGenerator` / `UISelectionFeedbackGenerator` calls inside
 * mobile views.
 *
 * Falls back to the [HapticFeedback] composition local for older Android
 * versions and degrades to a no-op when the device has no vibrator.
 */
enum class HapticEvent {
    /** Quick confirmation for taps on primary actions (send, allow, scan ok). */
    LightTap,
    /** Picker / segmented control selection. */
    Selection,
    /** Destructive or distinct edges (deny permission, archive, error). */
    HeavyImpact,
}

class HapticPlayer internal constructor(
    private val compose: HapticFeedback,
    private val view: android.view.View?,
) {
    fun play(event: HapticEvent) {
        // The Compose haptic API covers the lightest tier reliably; for
        // stronger feedback (deny / archive) we fall through to the View
        // performHapticFeedback APIs that map to platform HapticFeedbackConstants.
        when (event) {
            HapticEvent.LightTap ->
                compose.performHapticFeedback(HapticFeedbackType.TextHandleMove)
            HapticEvent.Selection ->
                compose.performHapticFeedback(HapticFeedbackType.LongPress)
            HapticEvent.HeavyImpact -> {
                val constant = android.view.HapticFeedbackConstants.REJECT
                if (view?.performHapticFeedback(constant) == true) return
                compose.performHapticFeedback(HapticFeedbackType.LongPress)
            }
        }
    }
}

@Composable
fun rememberHaptics(): HapticPlayer {
    val compose = LocalHapticFeedback.current
    val view = LocalView.current
    return remember(compose, view) { HapticPlayer(compose, view) }
}

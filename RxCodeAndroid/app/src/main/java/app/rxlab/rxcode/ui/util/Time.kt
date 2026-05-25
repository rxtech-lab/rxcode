package app.rxlab.rxcode.ui.util

import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.abs

/**
 * Human-friendly "N minutes ago" / "in N hours" formatter matching the
 * iOS `Date.formatted(.relative(presentation: .named))` style closely enough
 * that briefing / thread cards read consistently across platforms. Falls back
 * to an absolute date once the delta is more than ~6 days.
 */
fun relativeTime(instant: Instant, now: Instant = Instant.now()): String {
    val delta = Duration.between(instant, now)
    val absSeconds = abs(delta.seconds)
    val past = delta.seconds >= 0

    fun word(noun: String, count: Long) = if (count == 1L) "1 $noun" else "$count ${noun}s"
    fun phrase(text: String) = if (past) "$text ago" else "in $text"

    return when {
        absSeconds < 5 -> "just now"
        absSeconds < 60 -> phrase("$absSeconds sec")
        absSeconds < 3_600 -> phrase(word("min", absSeconds / 60))
        absSeconds < 86_400 -> phrase(word("hr", absSeconds / 3_600))
        absSeconds < 6 * 86_400 -> phrase(word("day", absSeconds / 86_400))
        else -> absoluteDate(instant)
    }
}

private val absoluteFormatter = DateTimeFormatter
    .ofPattern("MMM d", Locale.getDefault())
    .withZone(ZoneId.systemDefault())

fun absoluteDate(instant: Instant): String = absoluteFormatter.format(instant)

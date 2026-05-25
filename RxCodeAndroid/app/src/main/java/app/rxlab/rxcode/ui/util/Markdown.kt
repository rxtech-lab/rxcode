package app.rxlab.rxcode.ui.util

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextAlign
import dev.jeziellago.compose.markdowntext.MarkdownText

/**
 * Thin wrapper around `dev.jeziellago:compose-markdown` (a Markwon-backed
 * Compose renderer) that pins styling to the active MaterialTheme. Lets chat
 * bubbles, briefing summaries, and tool-call results all render rich text
 * (headings, bold, italic, code spans, lists, links) without each call site
 * having to repeat the same `MarkdownText` arguments.
 */
@Composable
fun RxMarkdownText(
    markdown: String,
    modifier: Modifier = Modifier,
    color: Color = MaterialTheme.colorScheme.onSurface,
    style: TextStyle = MaterialTheme.typography.bodyMedium,
    textAlign: TextAlign? = null,
    maxLines: Int = Int.MAX_VALUE,
    linkColor: Color = MaterialTheme.colorScheme.primary,
) {
    val resolvedStyle = remember(style, color, textAlign) {
        style.copy(color = color, textAlign = textAlign ?: style.textAlign)
    }
    MarkdownText(
        markdown = markdown,
        modifier = modifier,
        style = resolvedStyle,
        maxLines = maxLines,
        linkColor = linkColor,
    )
}

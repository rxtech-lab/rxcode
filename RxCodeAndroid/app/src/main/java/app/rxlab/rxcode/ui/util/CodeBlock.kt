package app.rxlab.rxcode.ui.util

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay

/** A piece of assistant markdown: either prose or a fenced code block. */
sealed interface MarkdownSegment {
    data class Prose(val text: String) : MarkdownSegment
    data class Code(val language: String, val content: String) : MarkdownSegment
}

private val fencedCodeRegex =
    Regex("```[ \\t]*([A-Za-z0-9_+#.-]*)[ \\t]*\\r?\\n([\\s\\S]*?)```", RegexOption.MULTILINE)

/**
 * Split markdown into prose and fenced-code segments so code can be rendered with
 * syntax highlighting while prose keeps going through the markdown renderer.
 * Inline code spans (single backticks) are left inside the prose.
 */
fun splitMarkdownCodeBlocks(markdown: String): List<MarkdownSegment> {
    val segments = mutableListOf<MarkdownSegment>()
    var last = 0
    for (match in fencedCodeRegex.findAll(markdown)) {
        if (match.range.first > last) {
            val prose = markdown.substring(last, match.range.first)
            if (prose.isNotBlank()) segments.add(MarkdownSegment.Prose(prose))
        }
        val language = match.groupValues[1].trim()
        val content = match.groupValues[2].removeSuffix("\n")
        segments.add(MarkdownSegment.Code(language, content))
        last = match.range.last + 1
    }
    if (last < markdown.length) {
        val tail = markdown.substring(last)
        if (tail.isNotBlank()) segments.add(MarkdownSegment.Prose(tail))
    }
    if (segments.isEmpty()) segments.add(MarkdownSegment.Prose(markdown))
    return segments
}

/**
 * Renders assistant markdown, routing fenced code blocks through the tree-sitter
 * [HighlightedCodeBlock] and everything else through [RxMarkdownText].
 */
@Composable
fun MarkdownWithCode(
    markdown: String,
    modifier: Modifier = Modifier,
    color: Color = MaterialTheme.colorScheme.onSurface,
    style: TextStyle = MaterialTheme.typography.bodyMedium,
    linkColor: Color = MaterialTheme.colorScheme.primary,
) {
    val segments = remember(markdown) { splitMarkdownCodeBlocks(markdown) }
    // Fast path: no fenced code — render exactly as before.
    if (segments.size == 1 && segments[0] is MarkdownSegment.Prose) {
        RxMarkdownText(markdown = markdown, modifier = modifier, color = color, style = style, linkColor = linkColor)
        return
    }
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        for (segment in segments) {
            when (segment) {
                is MarkdownSegment.Prose -> RxMarkdownText(
                    markdown = segment.text.trim(),
                    color = color,
                    style = style,
                    linkColor = linkColor,
                )
                is MarkdownSegment.Code -> HighlightedCodeBlock(
                    code = segment.content,
                    language = segment.language,
                )
            }
        }
    }
}

/**
 * A fenced code block with a language label, copy button, and tree-sitter syntax
 * highlighting. Highlighting is computed off the main thread; until it resolves
 * (or when the language is unsupported) plain monospaced text is shown.
 */
@Composable
fun HighlightedCodeBlock(
    code: String,
    language: String,
    modifier: Modifier = Modifier,
) {
    val dark = isSystemInDarkTheme()
    val clipboard = LocalClipboardManager.current
    val scheme = MaterialTheme.colorScheme

    var highlighted by remember(code, language, dark) { mutableStateOf<AnnotatedString?>(null) }
    LaunchedEffect(code, language, dark) {
        highlighted = if (CodeHighlighter.supports(language)) {
            CodeHighlighter.highlight(code, language, dark)
        } else {
            null
        }
    }

    var copied by remember { mutableStateOf(false) }
    LaunchedEffect(copied) {
        if (copied) {
            delay(2000)
            copied = false
        }
    }

    Column(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .border(0.5.dp, scheme.outlineVariant, RoundedCornerShape(8.dp)),
    ) {
        Row(
            Modifier
                .fillMaxWidth()
                .background(scheme.surfaceVariant)
                .padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (language.isNotBlank()) {
                Text(
                    text = language,
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = FontFamily.Monospace,
                    color = scheme.onSurfaceVariant,
                )
            }
            Row(
                Modifier
                    .weight(1f)
                    .padding(start = 8.dp),
                horizontalArrangement = Arrangement.End,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    imageVector = if (copied) Icons.Outlined.Check else Icons.Outlined.ContentCopy,
                    contentDescription = "Copy code",
                    tint = if (copied) Color(0xFF4CAF50) else scheme.onSurfaceVariant,
                    modifier = Modifier
                        .clip(RoundedCornerShape(4.dp))
                        .clickable {
                            clipboard.setText(AnnotatedString(code))
                            copied = true
                        }
                        .padding(2.dp),
                )
            }
        }

        val horizontalScroll = rememberScrollState()
        Text(
            text = highlighted ?: AnnotatedString(code),
            modifier = Modifier
                .fillMaxWidth()
                .background(scheme.surface)
                .horizontalScroll(horizontalScroll)
                .padding(12.dp),
            fontFamily = FontFamily.Monospace,
            fontSize = 13.sp,
            color = scheme.onSurface,
            softWrap = false,
            textAlign = TextAlign.Start,
        )
    }
}

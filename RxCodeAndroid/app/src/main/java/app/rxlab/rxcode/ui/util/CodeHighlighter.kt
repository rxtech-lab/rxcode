package app.rxlab.rxcode.ui.util

import android.content.Context
import android.util.Log
import android.util.LruCache
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import com.itsaky.androidide.treesitter.TSLanguage
import com.itsaky.androidide.treesitter.TSParser
import com.itsaky.androidide.treesitter.TSQuery
import com.itsaky.androidide.treesitter.TSQueryCursor
import com.itsaky.androidide.treesitter.TreeSitter
import com.itsaky.androidide.treesitter.c.TSLanguageC
import com.itsaky.androidide.treesitter.cpp.TSLanguageCpp
import com.itsaky.androidide.treesitter.java.TSLanguageJava
import com.itsaky.androidide.treesitter.json.TSLanguageJson
import com.itsaky.androidide.treesitter.kotlin.TSLanguageKotlin
import com.itsaky.androidide.treesitter.python.TSLanguagePython
import com.itsaky.androidide.treesitter.xml.TSLanguageXml
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.concurrent.ConcurrentHashMap

/**
 * Tree-sitter backed syntax highlighter for Android.
 *
 * Parses a code string with the matching grammar and applies its
 * `highlights.scm` capture colors to produce a Compose [AnnotatedString].
 * Grammars ship as native AARs (android-tree-sitter); the highlight queries are
 * shipped as app assets under `assets/queries/<lang>/highlights.scm`.
 *
 * Only the languages with a bundled grammar are highlighted — Kotlin, Java,
 * Python, C, C++, JSON, and XML. Everything else (and any failure) degrades to
 * plain text. All native work runs off the main thread and behind a lock, and
 * results are cached.
 */
object CodeHighlighter {
    private const val TAG = "CodeHighlighter"

    @Volatile private var available = false
    private lateinit var appContext: Context

    private class Grammar(val makeLanguage: () -> TSLanguage, val queryAsset: String)

    private val grammars: Map<String, Grammar> = mapOf(
        "kotlin" to Grammar({ TSLanguageKotlin.getInstance() }, "queries/kotlin/highlights.scm"),
        "java" to Grammar({ TSLanguageJava.getInstance() }, "queries/java/highlights.scm"),
        "python" to Grammar({ TSLanguagePython.getInstance() }, "queries/python/highlights.scm"),
        "json" to Grammar({ TSLanguageJson.getInstance() }, "queries/json/highlights.scm"),
        "c" to Grammar({ TSLanguageC.getInstance() }, "queries/c/highlights.scm"),
        "cpp" to Grammar({ TSLanguageCpp.getInstance() }, "queries/cpp/highlights.scm"),
        "xml" to Grammar({ TSLanguageXml.getInstance() }, "queries/xml/highlights.scm"),
    )

    // Native objects are not safe to touch concurrently; serialize all parsing.
    private val nativeLock = Any()
    private val compiledQueries = ConcurrentHashMap<String, TSQuery>()
    private val failedLanguages = ConcurrentHashMap.newKeySet<String>()
    private val resultCache = object : LruCache<String, AnnotatedString>(128) {}

    /** Loads the tree-sitter native library. Safe to call once at startup. */
    fun initialize(context: Context) {
        appContext = context.applicationContext
        available = try {
            TreeSitter.loadLibrary()
            true
        } catch (t: Throwable) {
            Log.w(TAG, "tree-sitter native library failed to load; highlighting disabled", t)
            false
        }
    }

    /** Canonical grammar key for a markdown/file language identifier. */
    fun normalize(language: String): String = when (language.lowercase().trim()) {
        "kt", "kts", "kotlin" -> "kotlin"
        "java" -> "java"
        "py", "python", "py3" -> "python"
        "json", "jsonc", "json5", "geojson" -> "json"
        "c", "h" -> "c"
        "cpp", "cc", "cxx", "c++", "hpp", "hh", "hxx" -> "cpp"
        "xml", "xsd", "xsl", "svg", "plist" -> "xml"
        else -> language.lowercase().trim()
    }

    /** True when a grammar is available to highlight [language]. */
    fun supports(language: String): Boolean =
        available && grammars.containsKey(normalize(language))

    /**
     * Highlight [code] for [language], producing a colored [AnnotatedString].
     * Returns plain text when the language is unsupported or parsing fails.
     */
    suspend fun highlight(code: String, language: String, dark: Boolean): AnnotatedString =
        withContext(Dispatchers.Default) {
            val key = normalize(language)
            val grammar = grammars[key]
            if (!available || grammar == null || code.isEmpty()) {
                return@withContext AnnotatedString(code)
            }
            val cacheKey = "$key|$dark|$code"
            resultCache.get(cacheKey)?.let { return@withContext it }

            val result = try {
                buildHighlighted(code, key, grammar, dark)
            } catch (t: Throwable) {
                Log.w(TAG, "highlighting failed for $key; falling back to plain text", t)
                AnnotatedString(code)
            }
            resultCache.put(cacheKey, result)
            result
        }

    private fun buildHighlighted(code: String, key: String, grammar: Grammar, dark: Boolean): AnnotatedString {
        val spans = ArrayList<Span>()
        synchronized(nativeLock) {
            val query = compiledQuery(key, grammar) ?: return AnnotatedString(code)
            val parser = TSParser.create()
            try {
                parser.setLanguage(grammar.makeLanguage())
                val tree = parser.parseString(code) ?: return AnnotatedString(code)
                try {
                    val cursor = TSQueryCursor.create()
                    try {
                        cursor.exec(query, tree.rootNode)
                        var match = cursor.nextMatch()
                        while (match != null) {
                            for (capture in match.captures) {
                                val name = query.getCaptureNameForId(capture.index)
                                val node = capture.node
                                spans.add(Span(node.startByte, node.endByte, name))
                            }
                            match = cursor.nextMatch()
                        }
                    } finally {
                        cursor.close()
                    }
                } finally {
                    tree.close()
                }
            } finally {
                parser.close()
            }
        }

        val length = code.length
        return buildAnnotatedString {
            append(code)
            for (span in spans) {
                // android-tree-sitter offsets are UTF-16 byte offsets; the Kotlin
                // String is UTF-16, so divide by two to get char indices.
                val start = span.startByte / 2
                val end = span.endByte / 2
                if (start in 0..length && end in start..length && start < end) {
                    styleFor(span.capture, dark)?.let { addStyle(it, start, end) }
                }
            }
        }
    }

    private fun compiledQuery(key: String, grammar: Grammar): TSQuery? {
        compiledQueries[key]?.let { return it }
        if (failedLanguages.contains(key)) return null
        return try {
            val scm = appContext.assets.open(grammar.queryAsset).bufferedReader().use { it.readText() }
            val query = TSQuery.create(grammar.makeLanguage(), scm)
            compiledQueries[key] = query
            query
        } catch (t: Throwable) {
            // A query authored for a newer grammar can reference unknown node
            // types; remember the failure and fall back to plain text.
            Log.w(TAG, "failed to compile highlights query for $key", t)
            failedLanguages.add(key)
            null
        }
    }

    // MARK: - Capture → style mapping

    private class Span(val startByte: Int, val endByte: Int, val capture: String)

    private fun styleFor(capture: String, dark: Boolean): SpanStyle? {
        var key = capture
        while (true) {
            palette[key]?.let { entry ->
                return SpanStyle(
                    color = if (dark) entry.dark else entry.light,
                    fontWeight = if (entry.bold) FontWeight.Medium else null,
                )
            }
            val dot = key.lastIndexOf('.')
            if (dot < 0) return null
            key = key.substring(0, dot)
        }
    }

    private class Style(val light: Color, val dark: Color, val bold: Boolean = false)

    private val palette: Map<String, Style> = mapOf(
        "keyword" to Style(Color(0xFFAF3A93), Color(0xFFFF7AB2), bold = true),
        "conditional" to Style(Color(0xFFAF3A93), Color(0xFFFF7AB2), bold = true),
        "repeat" to Style(Color(0xFFAF3A93), Color(0xFFFF7AB2), bold = true),
        "include" to Style(Color(0xFFAF3A93), Color(0xFFFF7AB2), bold = true),
        "exception" to Style(Color(0xFFAF3A93), Color(0xFFFF7AB2), bold = true),
        "boolean" to Style(Color(0xFFAF3A93), Color(0xFFFF7AB2)),
        "operator" to Style(Color(0xFF3C3929), Color(0xFFCCC9C0)),
        "string" to Style(Color(0xFFC4442D), Color(0xFFFF8170)),
        "character" to Style(Color(0xFFC4442D), Color(0xFFFF8170)),
        "comment" to Style(Color(0xFF72962A), Color(0xFF7EC856)),
        "number" to Style(Color(0xFF1C00CF), Color(0xFFD0BF69)),
        "float" to Style(Color(0xFF1C00CF), Color(0xFFD0BF69)),
        "constant" to Style(Color(0xFF1C00CF), Color(0xFFD0BF69)),
        "type" to Style(Color(0xFF5B2699), Color(0xFFDABAFF), bold = true),
        "constructor" to Style(Color(0xFF5B2699), Color(0xFFDABAFF), bold = true),
        "namespace" to Style(Color(0xFF5B2699), Color(0xFFDABAFF)),
        "module" to Style(Color(0xFF5B2699), Color(0xFFDABAFF)),
        "function" to Style(Color(0xFF326D74), Color(0xFF78C2B3)),
        "method" to Style(Color(0xFF326D74), Color(0xFF78C2B3)),
        "property" to Style(Color(0xFF3E6D74), Color(0xFF78C2B3)),
        "field" to Style(Color(0xFF3E6D74), Color(0xFF78C2B3)),
        "attribute" to Style(Color(0xFF947100), Color(0xFFFFA14F)),
        "annotation" to Style(Color(0xFF947100), Color(0xFFFFA14F)),
        "decorator" to Style(Color(0xFF947100), Color(0xFFFFA14F)),
        "label" to Style(Color(0xFF947100), Color(0xFFFFA14F)),
        "escape" to Style(Color(0xFF947100), Color(0xFFFFA14F)),
        "tag" to Style(Color(0xFFAF3A93), Color(0xFFFF7AB2), bold = true),
        "variable" to Style(Color(0xFF3C3929), Color(0xFFCCC9C0)),
        "parameter" to Style(Color(0xFF3C3929), Color(0xFFCCC9C0)),
        "punctuation" to Style(Color(0xFF3C3929), Color(0xFFCCC9C0)),
    )
}

package app.rxlab.rxcode.ui.search

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.Article
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material.icons.outlined.Clear
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import app.rxlab.rxcode.proto.DocsSearchHit
import app.rxlab.rxcode.proto.Project
import app.rxlab.rxcode.proto.SearchHit
import app.rxlab.rxcode.state.MobileAppState
import app.rxlab.rxcode.state.MobileState
import app.rxlab.rxcode.ui.util.RxMarkdownText

private enum class SearchScope(val label: String) { ALL("All"), THREADS("Threads"), DOCS("Docs") }

/**
 * Global search across threads + published docs. Mirrors iOS `MobileSearchView`:
 * a search field, an All / Threads / Docs scope selector with live match counts,
 * and result cards. Tapping a thread opens its chat; tapping a doc opens an
 * on-demand markdown viewer. One debounced `searchThreadsAndDocs` autopilot call
 * (see [MobileAppState.updateSearchQuery]) feeds both result lists.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SearchScreen(
    state: MobileState,
    viewModel: MobileAppState,
    onOpenSession: (String) -> Unit,
    onClose: () -> Unit,
) {
    BackHandler(onBack = onClose)

    var scope by remember { mutableStateOf(SearchScope.ALL) }
    var openDoc by remember { mutableStateOf<DocsSearchHit?>(null) }
    val projectsById = remember(state.projects) { state.projects.associateBy { it.id } }
    val hasQuery = state.searchQuery.trim().isNotEmpty()
    val settled = hasQuery && !state.isSearching

    fun count(scopeFor: SearchScope): Int = when (scopeFor) {
        SearchScope.ALL -> state.searchThreadHits.size + state.searchDocHits.size
        SearchScope.THREADS -> state.searchThreadHits.size
        SearchScope.DOCS -> state.searchDocHits.size
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            Column(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 8.dp, vertical = 8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = onClose) {
                        Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = "Close search")
                    }
                    TextField(
                        value = state.searchQuery,
                        onValueChange = viewModel::updateSearchQuery,
                        modifier = Modifier.weight(1f),
                        placeholder = { Text("Search threads and docs") },
                        leadingIcon = { Icon(Icons.Outlined.Search, contentDescription = null) },
                        trailingIcon = {
                            if (hasQuery) {
                                IconButton(onClick = { viewModel.clearSearch() }) {
                                    Icon(Icons.Outlined.Clear, contentDescription = "Clear")
                                }
                            }
                        },
                        singleLine = true,
                        keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(imeAction = ImeAction.Search),
                        colors = TextFieldDefaults.colors(
                            focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                            unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                            focusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent,
                            unfocusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent,
                        ),
                        shape = MaterialTheme.shapes.large,
                    )
                }
                Row(Modifier.fillMaxWidth().padding(top = 10.dp)) {
                    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                        SearchScope.entries.forEachIndexed { index, item ->
                            SegmentedButton(
                                selected = scope == item,
                                onClick = { scope = item },
                                shape = SegmentedButtonDefaults.itemShape(index, SearchScope.entries.size),
                            ) {
                                Text(if (settled) "${item.label} (${count(item)})" else item.label)
                            }
                        }
                    }
                }
            }
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when {
                !hasQuery -> CenteredHint("Search your threads and published docs.")
                state.isSearching -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                        Text("Searching…", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                else -> {
                    val showThreads = scope != SearchScope.DOCS
                    val showDocs = scope != SearchScope.THREADS
                    val threadHits = if (showThreads) state.searchThreadHits else emptyList()
                    val docHits = if (showDocs) state.searchDocHits else emptyList()
                    if (threadHits.isEmpty() && docHits.isEmpty()) {
                        CenteredHint("No results for \"${state.searchQuery.trim()}\".")
                    } else {
                        LazyColumn(
                            modifier = Modifier.fillMaxSize(),
                            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp, vertical = 12.dp),
                            verticalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            if (threadHits.isNotEmpty()) {
                                item("threads-header") { SectionLabel("Threads") }
                                items(threadHits, key = { "t:${it.sessionID}" }) { hit ->
                                    ThreadHitCard(hit = hit, project = projectsById[hit.projectID], onClick = { onOpenSession(hit.sessionID) })
                                }
                            }
                            if (docHits.isNotEmpty()) {
                                item("docs-header") { SectionLabel("Docs") }
                                items(docHits, key = { "d:${it.stableId}" }) { hit ->
                                    DocHitCard(hit = hit, onClick = { openDoc = hit })
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    openDoc?.let { hit ->
        DocViewerSheet(viewModel = viewModel, hit = hit, onDismiss = { openDoc = null })
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(top = 4.dp, bottom = 2.dp),
    )
}

@Composable
private fun CenteredHint(text: String) {
    Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
        Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun ThreadHitCard(hit: SearchHit, project: Project?, onClick: () -> Unit) {
    ElevatedCard(onClick = onClick, modifier = Modifier.fillMaxWidth()) {
        Row(
            Modifier.fillMaxWidth().padding(14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    hit.title.ifBlank { "Untitled" },
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                )
                if (hit.snippet.isNotBlank()) {
                    Text(
                        hit.snippet,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 2,
                    )
                }
                project?.name?.let { Badge(it) }
            }
            Icon(
                Icons.AutoMirrored.Outlined.KeyboardArrowRight,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun DocHitCard(hit: DocsSearchHit, onClick: () -> Unit) {
    val title = hit.docId.ifBlank { hit.repositoryFullName ?: "Document" }
    ElevatedCard(onClick = onClick, modifier = Modifier.fillMaxWidth()) {
        Row(
            Modifier.fillMaxWidth().padding(14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(Icons.AutoMirrored.Outlined.Article, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, maxLines = 1)
                hit.snippet?.takeIf { it.isNotBlank() }?.let {
                    Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2)
                }
                hit.repositoryFullName?.let { Badge(it) }
            }
            Icon(
                Icons.AutoMirrored.Outlined.KeyboardArrowRight,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun Badge(text: String) {
    Surface(
        color = MaterialTheme.colorScheme.secondaryContainer,
        shape = MaterialTheme.shapes.small,
    ) {
        Text(
            text,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSecondaryContainer,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp),
        )
    }
}

/**
 * On-demand doc viewer. Fetches the rendered markdown for the tapped hit via the
 * docs `getDocument` autopilot call and renders it; mirrors iOS `MobileDocumentView`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DocViewerSheet(viewModel: MobileAppState, hit: DocsSearchHit, onDismiss: () -> Unit) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var content by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var isLoading by remember { mutableStateOf(true) }
    val repoId = hit.docsRepositoryId ?: hit.repositoryFullName

    LaunchedEffect(hit.stableId) {
        if (repoId == null) {
            error = "This document has no repository reference."
            isLoading = false
            return@LaunchedEffect
        }
        isLoading = true
        try {
            val detail = viewModel.autopilot.getDocument(repoId, hit.docId)
            content = detail.currentVersion?.content ?: ""
        } catch (t: Throwable) {
            error = t.message ?: "Couldn't load the document."
        }
        isLoading = false
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.surfaceContainerLow,
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .padding(bottom = 24.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                hit.docId.ifBlank { hit.repositoryFullName ?: "Document" },
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            when {
                isLoading -> Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
                error != null -> Text(error!!, color = MaterialTheme.colorScheme.error)
                content.isNullOrBlank() -> Text("This document is empty.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                else -> RxMarkdownText(markdown = content!!)
            }
        }
    }
}

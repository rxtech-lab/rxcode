package app.rxlab.rxcode.ui.autopilot

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.text.KeyboardOptions
import app.rxlab.rxcode.proto.AddDocsRepoBody
import app.rxlab.rxcode.proto.DocsDocument
import app.rxlab.rxcode.proto.DocsRepo
import app.rxlab.rxcode.state.AutopilotException
import app.rxlab.rxcode.state.AutopilotService
import app.rxlab.rxcode.ui.util.RxMarkdownText
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Composable
fun DocsScreen(
    service: AutopilotService,
    online: Boolean,
    nav: AutopilotNav,
) {
    val scope = rememberCoroutineScope()
    var search by remember { mutableStateOf("") }
    var repos by remember { mutableStateOf<List<DocsRepo>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var reloadKey by remember { mutableStateOf(0) }
    var showPicker by remember { mutableStateOf(false) }
    var deleteTarget by remember { mutableStateOf<DocsRepo?>(null) }

    LaunchedEffect(online, search, reloadKey) {
        if (!online) { isLoading = false; return@LaunchedEffect }
        if (search.isNotEmpty()) delay(300)
        isLoading = true
        errorMessage = null
        try {
            repos = service.listDocsRepos(search.ifBlank { null }).items
        } catch (e: AutopilotException) {
            errorMessage = e.message
        } finally {
            isLoading = false
        }
    }

    AutopilotScaffold(
        title = "Documentation",
        onBack = { nav.pop() },
        actions = {
            IconButton(enabled = online, onClick = { showPicker = true }) {
                Icon(Icons.Outlined.Add, contentDescription = "Add docs repository")
            }
        },
    ) { m ->
        Box(m.fillMaxSize()) {
            LazyColumn(
                Modifier.fillMaxSize(),
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                item {
                    OutlinedTextField(
                        value = search,
                        onValueChange = { search = it },
                        label = { Text("Search repositories") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                errorMessage?.let { item { AutopilotErrorRow(it) } }
                if (repos.isEmpty() && !isLoading) {
                    item { AutopilotEmptyState("No documentation repositories. Tap + to add one.") }
                }
                items(repos, key = { it.id }) { repo ->
                    RepoListCard(
                        title = repo.fullName,
                        subtitle = repo.documentsCount?.let { "$it document(s)" },
                        enabled = online,
                        onClick = { nav.push(AutopilotRoute.DocsRepoDetail(repo)) },
                        onDelete = { deleteTarget = repo },
                    )
                }
            }
            AutopilotLoadingOverlay(isLoading && repos.isEmpty())
        }
    }

    if (showPicker) {
        AutopilotRepoPicker(
            service = service,
            title = "Add Docs Repository",
            existingFullNames = repos.map { it.fullName }.toSet(),
            onSelect = { picked ->
                service.addDocsRepo(
                    AddDocsRepoBody(picked.installationId, picked.id, picked.fullName)
                )
                reloadKey++
            },
            onDismiss = { showPicker = false },
        )
    }

    deleteTarget?.let { target ->
        AlertDialog(
            onDismissRequest = { deleteTarget = null },
            title = { Text("Remove repository?") },
            text = { Text("This removes the repository and its indexed documents from docs search.") },
            confirmButton = {
                TextButton(onClick = {
                    deleteTarget = null
                    scope.launch {
                        try { service.deleteDocsRepo(target.id); reloadKey++ }
                        catch (e: AutopilotException) { errorMessage = e.message }
                    }
                }) { Text("Remove", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { deleteTarget = null }) { Text("Cancel") } },
        )
    }
}

@Composable
fun DocsRepoScreen(
    service: AutopilotService,
    repo: DocsRepo,
    online: Boolean,
    onBack: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var documents by remember { mutableStateOf<List<DocsDocument>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }
    var isInstallingSecret by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var statusMessage by remember { mutableStateOf<String?>(null) }
    var reloadKey by remember { mutableStateOf(0) }
    var viewingDoc by remember { mutableStateOf<DocsDocument?>(null) }
    var deleteTarget by remember { mutableStateOf<DocsDocument?>(null) }
    var showUpload by remember { mutableStateOf(false) }

    LaunchedEffect(reloadKey) {
        if (!online) { isLoading = false; return@LaunchedEffect }
        isLoading = true
        errorMessage = null
        try {
            documents = service.listDocuments(repo.id).items
        } catch (e: AutopilotException) {
            errorMessage = e.message
        } finally {
            isLoading = false
        }
    }

    viewingDoc?.let { doc ->
        DocumentViewer(service, repo.id, doc, onBack = { viewingDoc = null })
        return
    }
    if (showUpload) {
        DocsUploadScreen(
            service = service,
            repoId = repo.id,
            online = online,
            onClose = { showUpload = false },
            onUploaded = { showUpload = false; statusMessage = "Document uploaded."; reloadKey++ },
        )
        return
    }

    AutopilotScaffold(
        title = repo.fullName,
        onBack = onBack,
        actions = {
            IconButton(enabled = online, onClick = { showUpload = true }) {
                Icon(Icons.Outlined.Add, contentDescription = "Add document")
            }
        },
    ) { m ->
        Box(m.fillMaxSize()) {
            LazyColumn(
                Modifier.fillMaxSize(),
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                errorMessage?.let { item { AutopilotErrorRow(it) } }
                statusMessage?.let { item { AutopilotSuccessRow(it) } }

                item { AutopilotSectionLabel("CI") }
                item {
                    Text(
                        "Mints a DOCS_UPLOAD_TOKEN and installs it as the repo's GitHub Actions " +
                            "secret so CI can publish docs automatically.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                item {
                    OutlinedButton(
                        enabled = online && !isInstallingSecret,
                        onClick = {
                            isInstallingSecret = true
                            errorMessage = null
                            statusMessage = null
                            scope.launch {
                                try {
                                    val r = service.installDocsGithubSecret(repo.id)
                                    statusMessage = "Installed ${r.secretName}."
                                } catch (e: AutopilotException) {
                                    errorMessage = e.message
                                } finally {
                                    isInstallingSecret = false
                                }
                            }
                        },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        if (isInstallingSecret) {
                            CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                            Text("  Installing…")
                        } else {
                            Icon(Icons.Outlined.Key, contentDescription = null, modifier = Modifier.size(18.dp))
                            Text("  Install CI upload token")
                        }
                    }
                }

                item { AutopilotSectionLabel("Documents") }
                if (documents.isEmpty() && !isLoading) {
                    item { AutopilotEmptyState("No documents indexed yet.") }
                }
                items(documents, key = { it.docId }) { doc ->
                    DocumentRow(doc, online, onOpen = { viewingDoc = doc }, onDelete = { deleteTarget = doc })
                }
            }
            AutopilotLoadingOverlay(isLoading && documents.isEmpty())
        }
    }

    deleteTarget?.let { target ->
        AlertDialog(
            onDismissRequest = { deleteTarget = null },
            title = { Text("Delete document?") },
            text = { Text(target.title ?: target.docId) },
            confirmButton = {
                TextButton(onClick = {
                    deleteTarget = null
                    scope.launch {
                        try { service.deleteDocument(repo.id, target.docId); reloadKey++ }
                        catch (e: AutopilotException) { errorMessage = e.message }
                    }
                }) { Text("Delete", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { deleteTarget = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun DocumentRow(
    doc: DocsDocument,
    online: Boolean,
    onOpen: () -> Unit,
    onDelete: () -> Unit,
) {
    ElevatedCard(
        modifier = Modifier.fillMaxWidth(),
        onClick = { if (online) onOpen() },
        colors = CardDefaults.elevatedCardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
    ) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Column(Modifier.weight(1f)) {
                Text(doc.title ?: doc.docId, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(doc.docId, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    doc.embeddingStatus?.let {
                        AssistChip(onClick = {}, enabled = false, label = { Text(it) })
                    }
                }
            }
            IconButton(onClick = onDelete) {
                Icon(Icons.Outlined.Delete, contentDescription = "Delete", tint = MaterialTheme.colorScheme.error)
            }
        }
    }
}

@Composable
private fun DocumentViewer(
    service: AutopilotService,
    repoId: String,
    doc: DocsDocument,
    onBack: () -> Unit,
) {
    var content by remember { mutableStateOf<String?>(null) }
    var isLoading by remember { mutableStateOf(true) }
    var errorMessage by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(doc.docId) {
        isLoading = true
        try {
            val detail = service.getDocument(repoId, doc.docId)
            content = detail.currentVersion?.content ?: "(no content)"
        } catch (e: AutopilotException) {
            errorMessage = e.message
        } finally {
            isLoading = false
        }
    }

    AutopilotScaffold(title = doc.docId, onBack = onBack) { m ->
        Box(m.fillMaxSize()) {
            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
            ) {
                errorMessage?.let { AutopilotErrorRow(it) }
                content?.let { RxMarkdownText(markdown = it) }
            }
            AutopilotLoadingOverlay(isLoading)
        }
    }
}

@Composable
private fun DocsUploadScreen(
    service: AutopilotService,
    repoId: String,
    online: Boolean,
    onClose: () -> Unit,
    onUploaded: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var docId by remember { mutableStateOf("") }
    var originalLink by remember { mutableStateOf("") }
    var content by remember { mutableStateOf("") }
    var isSaving by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }

    AutopilotScaffold(
        title = "Add Document",
        onBack = onClose,
        actions = {
            TextButton(
                enabled = online && !isSaving && docId.isNotBlank() && content.isNotBlank(),
                onClick = {
                    isSaving = true
                    errorMessage = null
                    scope.launch {
                        try {
                            service.uploadDocument(
                                repoId = repoId,
                                docId = docId.trim(),
                                content = content,
                                originalLink = originalLink.trim().ifBlank { null },
                            )
                            onUploaded()
                        } catch (e: AutopilotException) {
                            errorMessage = e.message
                        } finally {
                            isSaving = false
                        }
                    }
                },
            ) { Text("Upload") }
        },
    ) { m ->
        Column(
            m.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            OutlinedTextField(
                value = docId,
                onValueChange = { docId = it },
                label = { Text("Document ID (slug)") },
                placeholder = { Text("design/overview") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = originalLink,
                onValueChange = { originalLink = it },
                label = { Text("Source link (optional)") },
                placeholder = { Text("https://…") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = content,
                onValueChange = { content = it },
                label = { Text("Markdown") },
                minLines = 10,
                modifier = Modifier.fillMaxWidth(),
            )
            errorMessage?.let { AutopilotErrorRow(it) }
        }
    }
}

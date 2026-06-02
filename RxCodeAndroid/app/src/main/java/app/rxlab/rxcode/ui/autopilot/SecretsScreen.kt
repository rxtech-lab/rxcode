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
import androidx.compose.material.icons.outlined.Eco
import androidx.compose.material.icons.outlined.LockOpen
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material.icons.outlined.VpnKey
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CardDefaults
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.rxlab.rxcode.proto.AutopilotSecretFilePlaintext
import app.rxlab.rxcode.proto.SecretsEnvironment
import app.rxlab.rxcode.proto.SecretsFileMeta
import app.rxlab.rxcode.proto.SecretsManagedRepo
import app.rxlab.rxcode.state.AutopilotException
import app.rxlab.rxcode.state.MobileAppState
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Composable
fun SecretsScreen(
    app: MobileAppState,
    online: Boolean,
    nav: AutopilotNav,
) {
    var search by remember { mutableStateOf("") }
    var enrolled by remember { mutableStateOf<Boolean?>(null) }
    var repos by remember { mutableStateOf<List<SecretsManagedRepo>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }
    var errorMessage by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(online, search) {
        if (!online) { isLoading = false; return@LaunchedEffect }
        if (search.isNotEmpty()) delay(300)
        isLoading = true
        errorMessage = null
        try {
            if (enrolled == null) enrolled = app.secrets.enrollmentStatus()
            if (enrolled == true) {
                repos = app.autopilot.listRepos(search.ifBlank { null }).items
            }
        } catch (e: AutopilotException) {
            errorMessage = e.message
        } finally {
            isLoading = false
        }
    }

    AutopilotScaffold(title = "Secrets", onBack = { nav.pop() }) { m ->
        Box(m.fillMaxSize()) {
            LazyColumn(
                Modifier.fillMaxSize(),
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                errorMessage?.let { item { AutopilotErrorRow(it) } }

                when (enrolled) {
                    false -> item {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            Icon(Icons.Outlined.LockOpen, contentDescription = null, tint = AutopilotWarning)
                            Column {
                                Text("Encryption not set up", style = MaterialTheme.typography.titleSmall)
                                Text(
                                    "Enroll with your passkey on your Mac to manage secrets.",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                    }
                    true -> {
                        item {
                            OutlinedTextField(
                                value = search,
                                onValueChange = { search = it },
                                label = { Text("Search repositories") },
                                singleLine = true,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                        if (repos.isEmpty() && !isLoading) {
                            item { AutopilotEmptyState("No repositories available.") }
                        }
                        items(repos, key = { it.id }) { repo ->
                            SecretsRepoRow(repo, online) { nav.push(AutopilotRoute.SecretsRepo(repo.fullName)) }
                        }
                    }
                    null -> Unit
                }
            }
            AutopilotLoadingOverlay(enrolled == null && isLoading)
        }
    }
}

@Composable
private fun SecretsRepoRow(repo: SecretsManagedRepo, online: Boolean, onClick: () -> Unit) {
    ElevatedCard(
        modifier = Modifier.fillMaxWidth(),
        onClick = { if (online) onClick() },
        colors = CardDefaults.elevatedCardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
    ) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Icon(
                Icons.Outlined.VpnKey,
                contentDescription = null,
                tint = if (repo.isManaged) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Column(Modifier.weight(1f)) {
                Text(repo.fullName, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (repo.isManaged) {
                    Text(
                        "${repo.environmentsCount} environment(s), ${repo.filesCount} file(s)",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

@Composable
fun SecretsRepoScreen(
    app: MobileAppState,
    repo: String,
    online: Boolean,
    nav: AutopilotNav,
) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var environments by remember { mutableStateOf<List<SecretsEnvironment>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var reloadKey by remember { mutableStateOf(0) }
    var showCreate by remember { mutableStateOf(false) }
    var newName by remember { mutableStateOf("") }
    var deleteTarget by remember { mutableStateOf<SecretsEnvironment?>(null) }

    LaunchedEffect(reloadKey) {
        if (!online) { isLoading = false; return@LaunchedEffect }
        isLoading = true
        errorMessage = null
        try {
            environments = app.secrets.listEnvironments(repo)
        } catch (e: AutopilotException) {
            errorMessage = e.message
        } finally {
            isLoading = false
        }
    }

    AutopilotScaffold(
        title = repo,
        onBack = { nav.pop() },
        actions = {
            IconButton(enabled = online, onClick = { newName = ""; showCreate = true }) {
                Icon(Icons.Outlined.Add, contentDescription = "Add environment")
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
                if (environments.isEmpty() && !isLoading) {
                    item { AutopilotEmptyState("No environments yet. Tap + to add one.") }
                }
                items(environments, key = { it.id }) { env ->
                    ElevatedCard(
                        modifier = Modifier.fillMaxWidth(),
                        onClick = { if (online) nav.push(AutopilotRoute.SecretsEnv(repo, env)) },
                        colors = CardDefaults.elevatedCardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
                    ) {
                        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            Icon(Icons.Outlined.Eco, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                            Column(Modifier.weight(1f)) {
                                Text(env.name, style = MaterialTheme.typography.bodyLarge)
                                env.filesCount?.let {
                                    Text("$it file(s)", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            }
                            IconButton(onClick = { deleteTarget = env }) {
                                Icon(Icons.Outlined.Delete, contentDescription = "Delete", tint = MaterialTheme.colorScheme.error)
                            }
                        }
                    }
                }
            }
            AutopilotLoadingOverlay(isLoading && environments.isEmpty())
        }
    }

    if (showCreate) {
        AlertDialog(
            onDismissRequest = { showCreate = false },
            title = { Text("New environment") },
            text = {
                OutlinedTextField(
                    value = newName,
                    onValueChange = { newName = it },
                    label = { Text("Name") },
                    placeholder = { Text("production") },
                    singleLine = true,
                )
            },
            confirmButton = {
                TextButton(
                    enabled = newName.isNotBlank(),
                    onClick = {
                        val name = newName.trim()
                        showCreate = false
                        scope.launch {
                            try {
                                app.secrets.createEnvironment(context, repo, name)
                                reloadKey++
                            } catch (e: Exception) {
                                errorMessage = e.message
                            }
                        }
                    },
                ) { Text("Create") }
            },
            dismissButton = { TextButton(onClick = { showCreate = false }) { Text("Cancel") } },
        )
    }

    deleteTarget?.let { env ->
        AlertDialog(
            onDismissRequest = { deleteTarget = null },
            title = { Text("Delete environment?") },
            text = { Text("This permanently deletes the environment and its secret files.") },
            confirmButton = {
                TextButton(onClick = {
                    deleteTarget = null
                    scope.launch {
                        try { app.secrets.deleteEnvironment(repo, env.id); reloadKey++ }
                        catch (e: AutopilotException) { errorMessage = e.message }
                    }
                }) { Text("Delete", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { deleteTarget = null }) { Text("Cancel") } },
        )
    }
}

@Composable
fun SecretsEnvScreen(
    app: MobileAppState,
    repo: String,
    env: SecretsEnvironment,
    online: Boolean,
    onBack: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var files by remember { mutableStateOf<List<SecretsFileMeta>>(emptyList()) }
    var plaintextByName by remember { mutableStateOf<Map<String, String>>(emptyMap()) }
    var revealed by remember { mutableStateOf(false) }
    var isLoading by remember { mutableStateOf(true) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var reloadKey by remember { mutableStateOf(0) }
    var editing by remember { mutableStateOf<SecretsFileMeta?>(null) }
    var showAddFile by remember { mutableStateOf(false) }
    var deleteTarget by remember { mutableStateOf<SecretsFileMeta?>(null) }

    LaunchedEffect(reloadKey) {
        if (!online) { isLoading = false; return@LaunchedEffect }
        isLoading = true
        errorMessage = null
        try {
            files = app.secrets.listFiles(repo, env.id)
            if (revealed) {
                plaintextByName = app.secrets.environmentPlaintext(context, repo, env.id).associate { it.filename to it.content }
            }
        } catch (e: AutopilotException) {
            errorMessage = e.message
        } finally {
            isLoading = false
        }
    }

    if (showAddFile || editing != null) {
        SecretFileEditor(
            app = app,
            repo = repo,
            envId = env.id,
            existing = editing,
            existingContent = editing?.let { plaintextByName[it.filename] } ?: "",
            online = online,
            onClose = { showAddFile = false; editing = null },
            onSaved = {
                showAddFile = false
                editing = null
                reloadKey++
            },
        )
        return
    }

    AutopilotScaffold(
        title = env.name,
        onBack = onBack,
        actions = {
            IconButton(enabled = online, onClick = { showAddFile = true }) {
                Icon(Icons.Outlined.Add, contentDescription = "Add file")
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

                item {
                    OutlinedButton(
                        enabled = online,
                        onClick = {
                            scope.launch {
                                if (revealed) {
                                    revealed = false
                                    plaintextByName = emptyMap()
                                } else {
                                    try {
                                        plaintextByName = app.secrets
                                            .environmentPlaintext(context, repo, env.id)
                                            .associate { it.filename to it.content }
                                        revealed = true
                                    } catch (e: Exception) {
                                        errorMessage = e.message
                                    }
                                }
                            }
                        },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Icon(
                            if (revealed) Icons.Outlined.VisibilityOff else Icons.Outlined.Visibility,
                            contentDescription = null,
                            modifier = Modifier.size(18.dp),
                        )
                        Text(if (revealed) "  Hide values" else "  View values")
                    }
                }

                item { AutopilotSectionLabel("Files") }
                if (files.isEmpty() && !isLoading) {
                    item { AutopilotEmptyState("No files yet. Tap + to add one.") }
                }
                items(files, key = { it.id }) { file ->
                    ElevatedCard(
                        modifier = Modifier.fillMaxWidth(),
                        onClick = { if (online) editing = file },
                        colors = CardDefaults.elevatedCardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
                    ) {
                        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Column(Modifier.weight(1f)) {
                                Text(file.filename, style = MaterialTheme.typography.bodyLarge)
                                if (revealed) {
                                    plaintextByName[file.filename]?.let { preview ->
                                        Text(
                                            preview,
                                            style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                            maxLines = 3,
                                            overflow = TextOverflow.Ellipsis,
                                        )
                                    }
                                }
                            }
                            IconButton(onClick = { deleteTarget = file }) {
                                Icon(Icons.Outlined.Delete, contentDescription = "Delete", tint = MaterialTheme.colorScheme.error)
                            }
                        }
                    }
                }
            }
            AutopilotLoadingOverlay(isLoading && files.isEmpty())
        }
    }

    deleteTarget?.let { file ->
        AlertDialog(
            onDismissRequest = { deleteTarget = null },
            title = { Text("Delete file?") },
            text = { Text(file.filename) },
            confirmButton = {
                TextButton(onClick = {
                    deleteTarget = null
                    scope.launch {
                        try { app.secrets.deleteFile(repo, env.id, file.id); reloadKey++ }
                        catch (e: AutopilotException) { errorMessage = e.message }
                    }
                }) { Text("Delete", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { deleteTarget = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun SecretFileEditor(
    app: MobileAppState,
    repo: String,
    envId: String,
    existing: SecretsFileMeta?,
    existingContent: String,
    online: Boolean,
    onClose: () -> Unit,
    onSaved: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var filename by remember { mutableStateOf(existing?.filename ?: "") }
    var content by remember { mutableStateOf(existingContent) }
    var isSaving by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }

    AutopilotScaffold(
        title = existing?.filename ?: "Add File",
        onBack = onClose,
        actions = {
            TextButton(
                enabled = online && !isSaving && filename.isNotBlank(),
                onClick = {
                    isSaving = true
                    errorMessage = null
                    scope.launch {
                        try {
                            app.secrets.upsertFile(context, repo, envId, filename.trim(), content)
                            onSaved()
                        } catch (e: Exception) {
                            errorMessage = e.message
                        } finally {
                            isSaving = false
                        }
                    }
                },
            ) { Text("Save") }
        },
    ) { m ->
        Column(
            m.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            AutopilotSectionLabel("Filename")
            OutlinedTextField(
                value = filename,
                onValueChange = { filename = it },
                placeholder = { Text(".env") },
                singleLine = true,
                enabled = existing == null,
                modifier = Modifier.fillMaxWidth(),
            )
            AutopilotSectionLabel("Contents")
            OutlinedTextField(
                value = content,
                onValueChange = { content = it },
                minLines = 8,
                modifier = Modifier.fillMaxWidth(),
            )
            errorMessage?.let { AutopilotErrorRow(it) }
        }
    }
}

package app.rxlab.rxcode.ui.autopilot

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AddCircleOutline
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.MenuBook
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import app.rxlab.rxcode.proto.SecretsManagedRepo
import app.rxlab.rxcode.state.AutopilotException
import app.rxlab.rxcode.state.AutopilotService
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Shared "add repository" picker — mirrors iOS `MobileAutopilotRepoPicker`.
 * Lists accessible GitHub repos (paginated + searchable), excludes the ones
 * already managed, and invokes [onSelect] with the chosen repo.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AutopilotRepoPicker(
    service: AutopilotService,
    title: String,
    existingFullNames: Set<String>,
    onSelect: suspend (SecretsManagedRepo) -> Unit,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()

    var search by remember { mutableStateOf("") }
    var repos by remember { mutableStateOf<List<SecretsManagedRepo>>(emptyList()) }
    var cursor by remember { mutableStateOf<String?>(null) }
    var hasMore by remember { mutableStateOf(false) }
    var isLoading by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var addingFullName by remember { mutableStateOf<String?>(null) }

    val excluded = remember(existingFullNames) { existingFullNames.map { it.lowercase() }.toSet() }
    val visible = repos.filter { it.fullName.lowercase() !in excluded }

    // Debounced reload on search change + initial load.
    LaunchedEffect(search) {
        if (search.isNotEmpty()) delay(300)
        isLoading = true
        errorMessage = null
        try {
            val page = service.listRepos(search.ifBlank { null })
            repos = page.items
            cursor = page.pagination.nextCursor
            hasMore = page.pagination.hasMore
        } catch (e: AutopilotException) {
            errorMessage = e.message
        } finally {
            isLoading = false
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(Modifier.padding(horizontal = 16.dp).padding(bottom = 24.dp)) {
            Text(title, style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(bottom = 8.dp))
            OutlinedTextField(
                value = search,
                onValueChange = { search = it },
                label = { Text("Search repositories") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            errorMessage?.let { AutopilotErrorRow(it, Modifier.padding(top = 8.dp)) }

            Box(Modifier.fillMaxWidth().heightIn(min = 120.dp, max = 480.dp)) {
                LazyColumn(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    items(visible, key = { it.id }) { repo ->
                        RepoPickerRow(
                            repo = repo,
                            adding = addingFullName == repo.fullName,
                            enabled = addingFullName == null,
                            onClick = {
                                addingFullName = repo.fullName
                                scope.launch {
                                    try {
                                        onSelect(repo)
                                        onDismiss()
                                    } catch (e: AutopilotException) {
                                        errorMessage = e.message
                                        addingFullName = null
                                    }
                                }
                            },
                        )
                    }
                    if (hasMore) {
                        item {
                            TextButton(
                                enabled = !isLoading,
                                onClick = {
                                    scope.launch {
                                        isLoading = true
                                        try {
                                            val page = service.listRepos(search.ifBlank { null }, cursor)
                                            repos = repos + page.items
                                            cursor = page.pagination.nextCursor
                                            hasMore = page.pagination.hasMore
                                        } catch (e: AutopilotException) {
                                            errorMessage = e.message
                                        } finally {
                                            isLoading = false
                                        }
                                    }
                                },
                                modifier = Modifier.fillMaxWidth(),
                            ) { Text("Load more") }
                        }
                    }
                    if (visible.isEmpty() && !isLoading && errorMessage == null) {
                        item { AutopilotEmptyState("No repositories available to add.") }
                    }
                }
                if (isLoading && repos.isEmpty()) {
                    CircularProgressIndicator(Modifier.align(Alignment.Center))
                }
            }
        }
    }
}

@Composable
private fun RepoPickerRow(
    repo: SecretsManagedRepo,
    adding: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, onClick = onClick)
            .padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(
            if (repo.isPrivate) Icons.Outlined.Lock else Icons.Outlined.MenuBook,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(20.dp),
        )
        Column(Modifier.weight(1f)) {
            Text(repo.fullName, style = MaterialTheme.typography.bodyMedium)
            if (repo.isCurrent) {
                Text(
                    "Current project",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        if (adding) {
            CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
        } else {
            Icon(
                Icons.Outlined.AddCircleOutline,
                contentDescription = "Add",
                tint = MaterialTheme.colorScheme.primary,
            )
        }
    }
}

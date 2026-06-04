package app.rxlab.rxcode.ui.projects

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowForward
import androidx.compose.material.icons.automirrored.outlined.InsertDriveFile
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.rxlab.rxcode.proto.RemoteFolderNode
import app.rxlab.rxcode.state.MobileAppState
import app.rxlab.rxcode.state.MobileState
import app.rxlab.rxcode.ui.util.HapticEvent
import app.rxlab.rxcode.ui.util.rememberHaptics

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RemoteFolderPickerSheet(
    state: MobileState,
    viewModel: MobileAppState,
    onDismiss: () -> Unit,
) {
    val haptics = rememberHaptics()
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var navigationPath by remember { mutableStateOf<List<String>>(emptyList()) }
    var dismissedAfterCreateId by remember { mutableStateOf(state.lastCreatedProjectID) }

    val currentPath = navigationPath.lastOrNull()
    val currentNode = state.remoteFolderRoot
    val canAdd = currentNode != null &&
        currentNode.path.isNotBlank() &&
        currentNode.isSelectable &&
        !state.remoteProjectCreateInFlight

    LaunchedEffect(currentPath) {
        viewModel.requestRemoteFolder(path = currentPath)
    }

    LaunchedEffect(state.lastCreatedProjectID) {
        val createdId = state.lastCreatedProjectID ?: return@LaunchedEffect
        if (dismissedAfterCreateId != createdId) {
            dismissedAfterCreateId = createdId
            onDismiss()
        }
    }

    BackHandler(enabled = navigationPath.isNotEmpty()) {
        navigationPath = navigationPath.dropLast(1)
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.surfaceContainerLow,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(onClick = onDismiss) {
                    Icon(Icons.Outlined.Close, contentDescription = "Close")
                }
                Text(
                    "Add Project",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f),
                )
                IconButton(
                    enabled = canAdd,
                    onClick = {
                        val path = currentNode?.path ?: return@IconButton
                        haptics.play(HapticEvent.LightTap)
                        viewModel.createProjectFromRemoteFolder(path)
                    },
                ) {
                    if (state.remoteProjectCreateInFlight) {
                        CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                    } else {
                        Icon(Icons.Outlined.Add, contentDescription = "Add Project")
                    }
                }
            }

            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 240.dp, max = 560.dp),
            ) {
                when {
                    currentNode != null -> FolderList(
                        node = currentNode,
                        isLoading = state.remoteFolderIsLoading,
                        onOpen = { child ->
                            haptics.play(HapticEvent.Selection)
                            navigationPath = folderNavigationPath(child.path)
                        },
                    )

                    state.remoteFolderIsLoading -> LoadingFolders()

                    else -> FolderUnavailable(state.remoteFolderError)
                }

                if (state.remoteFolderIsLoading && currentNode != null) {
                    CircularProgressIndicator(Modifier.align(Alignment.Center))
                }
            }
        }
    }

    state.remoteFolderError?.let { message ->
        AlertDialog(
            onDismissRequest = { viewModel.clearRemoteFolderError() },
            confirmButton = {
                TextButton(onClick = { viewModel.requestRemoteFolder(path = currentPath) }) {
                    Text("Retry")
                }
            },
            dismissButton = {
                TextButton(onClick = { viewModel.clearRemoteFolderError() }) {
                    Text("OK")
                }
            },
            title = { Text("Unable to Load Folder") },
            text = { Text(message) },
        )
    }

    state.remoteProjectCreateError?.let { message ->
        AlertDialog(
            onDismissRequest = { viewModel.clearRemoteProjectCreateError() },
            confirmButton = {
                TextButton(
                    enabled = !currentNode?.path.isNullOrBlank(),
                    onClick = { viewModel.createProjectFromRemoteFolder(currentNode?.path.orEmpty()) },
                ) {
                    Text("Retry")
                }
            },
            dismissButton = {
                TextButton(onClick = { viewModel.clearRemoteProjectCreateError() }) {
                    Text("OK")
                }
            },
            title = { Text("Unable to Add Project") },
            text = { Text(message) },
        )
    }
}

@Composable
private fun FolderList(
    node: RemoteFolderNode,
    isLoading: Boolean,
    onOpen: (RemoteFolderNode) -> Unit,
) {
    LazyColumn(Modifier.fillMaxWidth()) {
        item {
            CurrentFolderRow(node)
        }
        if (node.children.isEmpty() && !isLoading) {
            item {
                EmptyFolderRow()
            }
        } else {
            items(node.children, key = { it.path }) { child ->
                if (child.isDirectory) {
                    FolderRow(child = child, onClick = { onOpen(child) })
                } else {
                    FileRow(child)
                }
            }
        }
    }
}

@Composable
private fun CurrentFolderRow(node: RemoteFolderNode) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(Icons.Outlined.Folder, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
        Column(Modifier.weight(1f)) {
            Text(node.name, style = MaterialTheme.typography.titleSmall)
            if (node.path.isNotBlank()) {
                Text(
                    node.path,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
private fun FolderRow(child: RemoteFolderNode, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(Icons.Outlined.Folder, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
        Column(Modifier.weight(1f)) {
            Text(child.name, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                child.path,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Icon(
            Icons.AutoMirrored.Outlined.ArrowForward,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.outline,
            modifier = Modifier.size(18.dp),
        )
    }
}

@Composable
private fun FileRow(child: RemoteFolderNode) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(Icons.AutoMirrored.Outlined.InsertDriveFile, contentDescription = null, tint = MaterialTheme.colorScheme.outline)
        Text(
            child.name,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun EmptyFolderRow() {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 40.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(Icons.Outlined.Folder, contentDescription = null, tint = MaterialTheme.colorScheme.outline)
        Text("No folders", style = MaterialTheme.typography.titleSmall)
        Text("This location has no visible folders.", color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun LoadingFolders() {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .height(240.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        CircularProgressIndicator()
        Spacer(Modifier.height(12.dp))
        Text("Loading folders", color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun FolderUnavailable(message: String?) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 48.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(Icons.Outlined.Folder, contentDescription = null, tint = MaterialTheme.colorScheme.outline)
        Text("Folders unavailable", style = MaterialTheme.typography.titleSmall)
        Text(
            message ?: "Connect to your Mac and try again.",
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

private fun folderNavigationPath(path: String): List<String> {
    val clean = path.trim().trimEnd('/')
    if (clean.isBlank()) return emptyList()
    if (clean == "/") return listOf("/")
    val components = clean.trim('/').split('/').filter { it.isNotBlank() }
    val paths = mutableListOf("/")
    var cursor = ""
    components.forEach { component ->
        cursor += "/$component"
        paths.add(cursor)
    }
    return paths
}

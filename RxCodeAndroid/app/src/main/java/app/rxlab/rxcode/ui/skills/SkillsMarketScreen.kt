package app.rxlab.rxcode.ui.skills

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.FilterList
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.Button
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.rxlab.rxcode.proto.MobileSkillPlugin
import app.rxlab.rxcode.state.MobileAppState
import app.rxlab.rxcode.ui.autopilot.AutopilotEmptyState
import app.rxlab.rxcode.ui.autopilot.AutopilotErrorRow
import app.rxlab.rxcode.ui.autopilot.AutopilotScaffold
import app.rxlab.rxcode.ui.autopilot.AutopilotSectionLabel

private const val FILTER_ALL = "All"
private const val FILTER_INSTALLED = "Installed"

/**
 * Browse the paired desktop's skill marketplace and install / remove skills
 * remotely. 1:1 with iOS `MobileSkillMarketView`: search + filter, plugins
 * grouped by category, and a custom Git-source sheet.
 */
@Composable
fun SkillsMarketScreen(
    app: MobileAppState,
    online: Boolean,
    onExit: () -> Unit,
) {
    val state by app.state.collectAsState()
    var searchText by remember { mutableStateOf("") }
    var selectedFilter by remember { mutableStateOf(FILTER_ALL) }
    var filterMenuOpen by remember { mutableStateOf(false) }
    var showGitSourceSheet by remember { mutableStateOf(false) }

    LaunchedEffect(online, state.activeDesktopPubkey, state.hasReceivedInitialSnapshot) {
        if (online &&
            state.hasReceivedInitialSnapshot &&
            !state.skillCatalogLoading &&
            state.skillCatalog.isEmpty()
        ) {
            app.requestSkillCatalog()
        }
    }

    val availableMarketplaces = remember(state.skillCatalog) {
        state.skillCatalog
            .groupingBy { it.marketplaceLabel }
            .eachCount()
            .entries
            .sortedByDescending { it.value }
            .map { it.key }
    }

    val filtered = remember(state.skillCatalog, searchText, selectedFilter) {
        filterPlugins(state.skillCatalog, searchText, selectedFilter)
    }
    val categories = remember(filtered) { filtered.map { it.categoryLabel }.toSortedSet().toList() }

    AutopilotScaffold(
        title = "Skills",
        onBack = onExit,
        actions = {
            IconButton(onClick = { filterMenuOpen = true }) {
                Icon(Icons.Outlined.FilterList, contentDescription = "Filter Skills")
            }
            DropdownMenu(expanded = filterMenuOpen, onDismissRequest = { filterMenuOpen = false }) {
                FilterRow(FILTER_ALL, selectedFilter) { selectedFilter = FILTER_ALL; filterMenuOpen = false }
                FilterRow(FILTER_INSTALLED, selectedFilter) { selectedFilter = FILTER_INSTALLED; filterMenuOpen = false }
                availableMarketplaces.forEach { label ->
                    FilterRow(label, selectedFilter) { selectedFilter = label; filterMenuOpen = false }
                }
            }
            IconButton(onClick = { showGitSourceSheet = true }, enabled = online) {
                Icon(Icons.Outlined.Add, contentDescription = "Add Git Source")
            }
            if (state.skillCatalogLoading) {
                CircularProgressIndicator(modifier = Modifier.size(20.dp))
            } else {
                IconButton(onClick = { app.requestSkillCatalog(forceRefresh = true) }, enabled = online) {
                    Icon(Icons.Outlined.Refresh, contentDescription = "Refresh")
                }
            }
        },
    ) { modifier ->
        LazyColumn(
            modifier = modifier.fillMaxSize(),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                OutlinedTextField(
                    value = searchText,
                    onValueChange = { searchText = it },
                    label = { Text("Search skills") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            state.skillCatalogError?.let { item { AutopilotErrorRow(it) } }
            state.lastSkillError?.let { item { AutopilotErrorRow(it) } }

            if (state.skillCatalog.isEmpty()) {
                item {
                    if (online && !state.hasReceivedInitialSnapshot) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            CircularProgressIndicator(modifier = Modifier.size(18.dp))
                            Text("Waiting for Mac sync…", style = MaterialTheme.typography.bodyMedium)
                        }
                    } else if (state.skillCatalogLoading) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            CircularProgressIndicator(modifier = Modifier.size(18.dp))
                            Text("Loading skills…", style = MaterialTheme.typography.bodyMedium)
                        }
                    } else if (state.skillCatalogError == null) {
                        AutopilotEmptyState("No skills found.")
                    }
                }
            } else if (filtered.isEmpty()) {
                item { AutopilotEmptyState("No skills found.") }
            } else {
                categories.forEach { category ->
                    item(key = "section-$category") { AutopilotSectionLabel(category) }
                    val plugins = filtered
                        .filter { it.categoryLabel == category }
                        .sortedBy { it.name.lowercase() }
                    items(plugins, key = { it.id }) { plugin ->
                        SkillRow(
                            plugin = plugin,
                            inFlight = state.inFlightSkillMutations.contains(plugin.id),
                            online = online,
                            onInstall = { app.installSkill(plugin.id) },
                            onRemove = { app.uninstallSkill(plugin.id) },
                        )
                    }
                }
            }
        }
    }

    if (showGitSourceSheet) {
        SkillGitSourceSheet(app = app, online = online, onDismiss = { showGitSourceSheet = false })
    }
}

@Composable
private fun FilterRow(label: String, selected: String, onClick: () -> Unit) {
    DropdownMenuItem(
        text = { Text(label) },
        onClick = onClick,
        trailingIcon = {
            if (selected == label) Icon(Icons.Outlined.Check, contentDescription = null)
        },
    )
}

@Composable
private fun SkillRow(
    plugin: MobileSkillPlugin,
    inFlight: Boolean,
    online: Boolean,
    onInstall: () -> Unit,
    onRemove: () -> Unit,
) {
    ElevatedCard(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.elevatedCardColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainer,
        ),
    ) {
        Row(
            Modifier.padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(plugin.name, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (plugin.summary.isNotEmpty()) {
                    Text(
                        plugin.summary,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Text(
                    plugin.marketplaceLabel,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            when {
                inFlight -> CircularProgressIndicator(modifier = Modifier.size(20.dp))
                plugin.isInstalled -> OutlinedButton(onClick = onRemove, enabled = online) { Text("Remove") }
                else -> Button(onClick = onInstall, enabled = online) { Text("Install") }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SkillGitSourceSheet(
    app: MobileAppState,
    online: Boolean,
    onDismiss: () -> Unit,
) {
    val state by app.state.collectAsState()
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var gitUrl by remember { mutableStateOf("") }
    var ref by remember { mutableStateOf("") }

    val addKey = "add:${gitUrl.trim()}"
    val canAdd = gitUrl.trim().isNotEmpty() &&
        !state.inFlightSkillSourceMutations.contains(addKey) &&
        online

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Git Sources", style = MaterialTheme.typography.titleLarge)
            OutlinedTextField(
                value = gitUrl,
                onValueChange = { gitUrl = it },
                label = { Text("https://github.com/owner/repo") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = ref,
                onValueChange = { ref = it },
                label = { Text("main") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            Text(
                "Use a GitHub repository that exposes .claude-plugin/marketplace.json.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            state.lastSkillError?.let { AutopilotErrorRow(it) }

            Button(
                onClick = {
                    app.addSkillGitSource(gitUrl, ref)
                    gitUrl = ""
                    ref = ""
                },
                enabled = canAdd,
                modifier = Modifier.fillMaxWidth(),
            ) {
                if (state.inFlightSkillSourceMutations.contains(addKey)) {
                    CircularProgressIndicator(modifier = Modifier.size(18.dp))
                } else {
                    Text("Add Source")
                }
            }

            AutopilotSectionLabel("Custom Sources")
            if (state.skillSources.isEmpty()) {
                AutopilotEmptyState("No custom Git sources added.")
            } else {
                state.skillSources.forEach { source ->
                    Row(
                        Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text(
                            source.displayName,
                            style = MaterialTheme.typography.bodyMedium,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                        if (state.inFlightSkillSourceMutations.contains(source.id)) {
                            CircularProgressIndicator(modifier = Modifier.size(18.dp))
                        } else {
                            IconButton(onClick = { app.removeSkillGitSource(source.id) }) {
                                Icon(
                                    Icons.Outlined.Delete,
                                    contentDescription = "Remove ${source.displayName}",
                                    tint = MaterialTheme.colorScheme.error,
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

/** Apply the marketplace/installed/search filters, mirroring the iOS logic. */
private fun filterPlugins(
    catalog: List<MobileSkillPlugin>,
    searchText: String,
    selectedFilter: String,
): List<MobileSkillPlugin> {
    var plugins = catalog
    when (selectedFilter) {
        FILTER_ALL -> Unit
        FILTER_INSTALLED -> plugins = plugins.filter { it.isInstalled }
        else -> plugins = plugins.filter { it.marketplaceLabel == selectedFilter }
    }
    val query = searchText.trim().lowercase()
    if (query.isEmpty()) return plugins
    return plugins.filter {
        it.name.lowercase().contains(query) ||
            it.summary.lowercase().contains(query) ||
            it.categoryLabel.lowercase().contains(query) ||
            it.marketplaceLabel.lowercase().contains(query)
    }
}

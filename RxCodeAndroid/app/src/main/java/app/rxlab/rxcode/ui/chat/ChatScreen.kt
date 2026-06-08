package app.rxlab.rxcode.ui.chat

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.Send
import androidx.compose.material.icons.automirrored.outlined.ViewSidebar
import androidx.compose.material.icons.outlined.Build
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Difference
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.PlayArrow
import androidx.compose.material.icons.outlined.QuestionAnswer
import androidx.compose.material.icons.outlined.QueuePlayNext
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.material.icons.outlined.KeyboardArrowDown
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import kotlinx.coroutines.launch
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.rxlab.rxcode.proto.ChatMessage
import app.rxlab.rxcode.proto.MenuAction
import app.rxlab.rxcode.proto.MenuCommandKind
import app.rxlab.rxcode.ui.autopilot.commandLoadingText
import app.rxlab.rxcode.proto.MenuItem
import app.rxlab.rxcode.proto.MessageBlock
import app.rxlab.rxcode.proto.PendingQuestionPayload
import app.rxlab.rxcode.proto.Role
import app.rxlab.rxcode.proto.ToolCall
import app.rxlab.rxcode.state.MobileAppState
import app.rxlab.rxcode.state.MobileState
import app.rxlab.rxcode.state.isDraftSessionId
import app.rxlab.rxcode.state.resolveSessionId
import app.rxlab.rxcode.state.runProfilesFor
import app.rxlab.rxcode.state.runTasksFor
import app.rxlab.rxcode.ui.autopilot.SerializedMenuItems
import app.rxlab.rxcode.ui.browser.BrowserUrlDetector
import app.rxlab.rxcode.ui.browser.InAppBrowserScreen
import app.rxlab.rxcode.proto.RunProfile
import app.rxlab.rxcode.ui.sheets.FileDiffSheet
import app.rxlab.rxcode.ui.sheets.PermissionApprovalSheet
import app.rxlab.rxcode.ui.sheets.QuestionSheet
import app.rxlab.rxcode.ui.sheets.QueuedMessagesSheet
import app.rxlab.rxcode.ui.sheets.RunProfileEditorSheet
import app.rxlab.rxcode.ui.sheets.RunProfilesSheet
import app.rxlab.rxcode.ui.sheets.ThreadChangesSheet
import app.rxlab.rxcode.ui.sheets.ThreadTodoSheet
import app.rxlab.rxcode.ui.sheets.TodoProgressBadge
import app.rxlab.rxcode.ui.sheets.ToolCallSheet
import app.rxlab.rxcode.proto.TodoExtractor
import app.rxlab.rxcode.proto.TodoItem
import app.rxlab.rxcode.ui.sheets.newBashRunProfile
import app.rxlab.rxcode.ui.util.HapticEvent
import app.rxlab.rxcode.ui.util.MarkdownWithCode
import app.rxlab.rxcode.ui.util.RxMarkdownText
import app.rxlab.rxcode.ui.util.rememberHaptics
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.delay
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject

private val compactJson = Json { prettyPrint = false }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatScreen(
    state: MobileState,
    viewModel: MobileAppState,
    sessionId: String,
    onBack: () -> Unit,
    isDetailExpanded: Boolean? = null,
    onToggleDetailExpanded: (() -> Unit)? = null,
) {
    val resolvedId = remember(sessionId, state.sessionIDRedirects) { state.resolveSessionId(sessionId) }
    val messages = state.messagesBySession[resolvedId].orEmpty()
    val session = state.sessions.firstOrNull { it.id == resolvedId }
    val isStreaming = session?.isStreaming == true
    val isThinking = state.thinkingSessions.contains(resolvedId)
    val isDraftSession = isDraftSessionId(resolvedId)
    val isThreadLoadingMessages = state.loadingThreadMessageSessions.contains(resolvedId)
    var openToolCall by remember { mutableStateOf<ToolCall?>(null) }
    var openQuestion by remember { mutableStateOf<PendingQuestionPayload?>(null) }
    var showQueuedSheet by remember { mutableStateOf(false) }
    var openEditPreview by remember { mutableStateOf<EditPreviewData?>(null) }
    var menuExpanded by remember { mutableStateOf(false) }
    val menuScope = rememberCoroutineScope()
    // Desktop-mediated thread actions (Code Review / Commit Files / Stop) come from
    // the Mac as its serialized thread menu — fetched lazily, re-keyed on the
    // gating state — so they match the desktop's items exactly.
    var threadMenu by remember(resolvedId) { mutableStateOf<List<MenuItem>?>(null) }
    LaunchedEffect(resolvedId, session?.hasRecordedFileChanges, session?.isStreaming) {
        threadMenu = if (isDraftSessionId(resolvedId)) null
        else runCatching { viewModel.fetchThreadMenu(resolvedId) }.getOrNull()
    }
    // Drives the loading dialog while an async thread command (e.g. a custom API
    // call) runs; `dispatchingThreadCommand` guards re-entrancy and `threadCommandError`
    // surfaces a failure to the user instead of silently swallowing it. Mirrors
    // `ProjectActionsMenu`.
    var dispatchingThreadCommand by remember { mutableStateOf(false) }
    var asyncThreadCommand by remember { mutableStateOf<MenuCommandKind?>(null) }
    var threadCommandError by remember { mutableStateOf<String?>(null) }
    fun runThreadAction(action: MenuAction?) {
        val command = (action as? MenuAction.Command)?.command ?: return
        if (dispatchingThreadCommand) return
        menuExpanded = false
        dispatchingThreadCommand = true
        if (command.isAsync) asyncThreadCommand = command.kind
        menuScope.launch {
            try {
                val result = viewModel.executeMenuCommand(command)
                viewModel.requestSnapshot("menu_command")
                result.threadId?.let { viewModel.selectSession(it) }
            } catch (t: Throwable) {
                threadCommandError = t.message ?: "Couldn't complete the action."
            } finally {
                dispatchingThreadCommand = false
                asyncThreadCommand = null
            }
        }
    }
    asyncThreadCommand?.let { kind ->
        val (title, message) = commandLoadingText(kind)
        AlertDialog(
            onDismissRequest = {},
            confirmButton = {},
            title = { Text(title) },
            text = {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    CircularProgressIndicator(modifier = Modifier.size(22.dp), strokeWidth = 2.dp)
                    Text(message)
                }
            },
        )
    }
    threadCommandError?.let { message ->
        AlertDialog(
            onDismissRequest = { threadCommandError = null },
            title = { Text("Couldn't Complete") },
            text = { Text(message) },
            confirmButton = { TextButton(onClick = { threadCommandError = null }) { Text("OK") } },
        )
    }

    var showRunProfiles by remember { mutableStateOf(false) }
    var editingProfile by remember { mutableStateOf<RunProfile?>(null) }
    var showBrowser by remember { mutableStateOf(false) }
    var showThreadChanges by remember { mutableStateOf(false) }
    var showTodoSheet by remember { mutableStateOf(false) }
    val todos = remember(messages) { TodoExtractor.latest(messages) }
    val threadSummary = remember(state.threadSummaries, resolvedId) {
        state.threadSummaries.firstOrNull { it.sessionId == resolvedId }
    }
    var minimumThreadLoadElapsed by remember(resolvedId) { mutableStateOf(false) }
    var threadLoadingOverlayVisible by remember(resolvedId) { mutableStateOf(true) }
    val pendingQuestion = state.pendingQuestions.firstOrNull { it.sessionID == resolvedId }

    val listState = rememberLazyListState()
    LaunchedEffect(resolvedId) {
        minimumThreadLoadElapsed = false
        threadLoadingOverlayVisible = true
        delay(1_000)
        minimumThreadLoadElapsed = true
    }
    LaunchedEffect(
        resolvedId,
        isDraftSession,
        isThreadLoadingMessages,
        messages.isEmpty(),
        minimumThreadLoadElapsed,
    ) {
        if (isDraftSession) {
            threadLoadingOverlayVisible = false
            return@LaunchedEffect
        }
        if (isThreadLoadingMessages || !minimumThreadLoadElapsed) {
            threadLoadingOverlayVisible = true
            return@LaunchedEffect
        }
        delay(500)
        threadLoadingOverlayVisible = false
    }
    LaunchedEffect(messages.size) {
        if (messages.isNotEmpty() && listState.firstVisibleItemIndex == 0) {
            listState.animateScrollToItem(0)
        }
    }
    LaunchedEffect(listState, resolvedId) {
        snapshotFlow { listState.layoutInfo }
            .filter { info -> info.visibleItemsInfo.isNotEmpty() }
            .filter { info ->
                val last = info.visibleItemsInfo.last()
                last.index >= info.totalItemsCount - 2 &&
                    state.sessionsWithMoreMessages.contains(resolvedId) &&
                    !state.loadingMoreSessions.contains(resolvedId)
            }
            .distinctUntilChanged()
            .collect { viewModel.loadMoreMessages() }
    }

    Scaffold(
        topBar = {
            CenterAlignedTopAppBar(
                title = {
                    val titleText = session?.title?.ifBlank { "Thread" } ?: "Thread"
                    val hasTodos = !todos.isNullOrEmpty()
                    val hasContent = hasTodos || (threadSummary?.summary?.isNotEmpty() == true)
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        modifier = if (hasContent) {
                            Modifier.clickable { showTodoSheet = true }
                        } else {
                            Modifier
                        },
                    ) {
                        Text(
                            titleText,
                            style = MaterialTheme.typography.titleMedium,
                            maxLines = 1,
                        )
                        if (hasTodos) {
                            val done = todos!!.count { it.status == TodoItem.Status.COMPLETED }
                            val inProgress = todos.any { it.status == TodoItem.Status.IN_PROGRESS }
                            TodoProgressBadge(
                                done = done,
                                total = todos.size,
                                inProgress = inProgress,
                            )
                        } else if (hasContent) {
                            Icon(
                                Icons.Outlined.ExpandMore,
                                contentDescription = "Show summary",
                                modifier = Modifier.size(14.dp),
                                tint = MaterialTheme.colorScheme.outline,
                            )
                        }
                    }
                },
                navigationIcon = {
                    if (isDetailExpanded != null && onToggleDetailExpanded != null) {
                        IconButton(onClick = onToggleDetailExpanded) {
                            Icon(
                                Icons.AutoMirrored.Outlined.ViewSidebar,
                                contentDescription = if (isDetailExpanded) {
                                    "Show content column"
                                } else {
                                    "Collapse content column"
                                },
                            )
                        }
                    } else {
                        IconButton(onClick = onBack) {
                            Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = "Back")
                        }
                    }
                },
                actions = {
                    val queueSize = session?.queuedMessages?.size ?: 0
                    if (queueSize > 0) {
                        IconButton(onClick = { showQueuedSheet = true }) {
                            androidx.compose.material3.BadgedBox(
                                badge = { androidx.compose.material3.Badge { Text(queueSize.toString()) } },
                            ) {
                                Icon(Icons.Outlined.QueuePlayNext, contentDescription = "Queued messages")
                            }
                        }
                    }
                    IconButton(onClick = { menuExpanded = true }) {
                        Icon(Icons.Outlined.MoreVert, contentDescription = "Thread actions")
                    }
                    androidx.compose.material3.DropdownMenu(
                        expanded = menuExpanded,
                        onDismissRequest = { menuExpanded = false },
                    ) {
                        androidx.compose.material3.DropdownMenuItem(
                            text = { Text("View Changes") },
                            onClick = {
                                menuExpanded = false
                                showThreadChanges = true
                            },
                            leadingIcon = { Icon(Icons.Outlined.Difference, contentDescription = null) },
                        )
                        // Desktop-built thread actions (Code Review / Commit Files /
                        // Stop Code Review), gated by the Mac — the single source of
                        // truth, matching iOS.
                        threadMenu?.takeIf { it.isNotEmpty() }?.let { items ->
                            SerializedMenuItems(items, onAction = ::runThreadAction)
                        }
                        androidx.compose.material3.DropdownMenuItem(
                            text = { Text("Open in Browser") },
                            onClick = {
                                menuExpanded = false
                                showBrowser = true
                            },
                            leadingIcon = { Icon(Icons.Outlined.Language, contentDescription = null) },
                        )
                        androidx.compose.material3.DropdownMenuItem(
                            text = { Text("Run Profiles") },
                            enabled = session?.projectId != null,
                            onClick = {
                                menuExpanded = false
                                showRunProfiles = true
                            },
                            leadingIcon = { Icon(Icons.Outlined.PlayArrow, contentDescription = null) },
                        )
                    }
                },
            )
        },
        bottomBar = {
            val haptics = rememberHaptics()
            Composer(
                isStreaming = isStreaming,
                onSend = { text ->
                    haptics.play(HapticEvent.LightTap)
                    viewModel.sendUserMessage(text)
                },
                onCancel = {
                    haptics.play(HapticEvent.HeavyImpact)
                    viewModel.cancelStream()
                },
            )
        }
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize().padding(horizontal = 12.dp),
                reverseLayout = true,
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                item("composer-gap") {
                    Spacer(Modifier.height(18.dp))
                }
                if (isStreaming || isThinking) {
                    item("indicator") { StreamingIndicator(thinking = isThinking) }
                }
                items(messages.asReversed(), key = { it.id.toString() }) { msg ->
                    MessageBubble(
                        msg = msg,
                        sessionId = resolvedId,
                        pendingQuestions = state.pendingQuestions,
                        onToolCallClick = { openToolCall = it },
                        onQuestionClick = { openQuestion = it },
                        onEditDetailsClick = { openEditPreview = it },
                    )
                }
                if (state.loadingMoreSessions.contains(resolvedId)) {
                    item("loading") {
                        Box(Modifier.fillMaxWidth().padding(8.dp), contentAlignment = Alignment.Center) {
                            CircularProgressIndicator()
                        }
                    }
                }
            }

            // Scroll-to-bottom FAB. With `reverseLayout = true` the newest
            // message lives at logical-top of the list (index 0), so we show
            // the FAB whenever the user has scrolled away from that index.
            val scope = rememberCoroutineScope()
            val showJumpToLatest by remember {
                derivedStateOf {
                    listState.firstVisibleItemIndex > 1 ||
                        listState.firstVisibleItemScrollOffset > 80
                }
            }
            androidx.compose.animation.AnimatedVisibility(
                visible = showJumpToLatest,
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(end = 16.dp, bottom = 12.dp),
                enter = androidx.compose.animation.fadeIn() + androidx.compose.animation.scaleIn(),
                exit = androidx.compose.animation.fadeOut() + androidx.compose.animation.scaleOut(),
            ) {
                androidx.compose.material3.SmallFloatingActionButton(
                    onClick = {
                        scope.launch { listState.animateScrollToItem(0) }
                    },
                    containerColor = MaterialTheme.colorScheme.primaryContainer,
                    contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                ) {
                    Icon(
                        androidx.compose.material.icons.Icons.Outlined.KeyboardArrowDown,
                        contentDescription = "Jump to latest",
                    )
                }
            }

            androidx.compose.animation.AnimatedVisibility(
                visible = !isDraftSession && messages.isEmpty() && threadLoadingOverlayVisible,
                enter = fadeIn(animationSpec = tween(180)) + scaleIn(
                    initialScale = 0.98f,
                    animationSpec = tween(180),
                ),
                exit = fadeOut(animationSpec = tween(220)) + slideOutVertically(
                    targetOffsetY = { it / 8 },
                    animationSpec = tween(220),
                ),
            ) {
                ThreadLoadingOverlay()
            }
        }
    }

    state.pendingPermission?.let { req ->
        PermissionApprovalSheet(
            request = req,
            onAllow = { viewModel.respondToPermission(allow = true) },
            onDeny = { viewModel.respondToPermission(allow = false, denyReason = "Denied") },
            onDismiss = { viewModel.respondToPermission(allow = false, denyReason = "Dismissed") },
        )
    }
    (openQuestion ?: pendingQuestion)?.let { q ->
        QuestionSheet(
            pending = q,
            onDismiss = {
                openQuestion = null
                viewModel.answerQuestion(q.toolUseID, emptyList())
            },
            onSubmit = { answers ->
                openQuestion = null
                viewModel.answerQuestion(q.toolUseID, answers)
            },
        )
    }
    openToolCall?.let { tc ->
        ToolCallSheet(toolCall = tc, onDismiss = { openToolCall = null })
    }
    if (showQueuedSheet) {
        QueuedMessagesSheet(
            queued = session?.queuedMessages.orEmpty(),
            onDismiss = { showQueuedSheet = false },
        )
    }
    openEditPreview?.let { preview ->
        FileDiffSheet(
            title = preview.title,
            subtitle = preview.subtitle,
            diffs = preview.diffs,
            onDismiss = { openEditPreview = null },
        )
    }

    val projectId = session?.projectId
    if (showRunProfiles && projectId != null) {
        RunProfilesSheet(
            profiles = state.runProfilesFor(projectId),
            tasks = state.runTasksFor(projectId),
            onRun = { viewModel.runRunProfile(projectId, it.id) },
            onStop = { task -> viewModel.stopRunTask(taskId = task.taskId, projectId = projectId) },
            onEdit = { editingProfile = it },
            onDelete = { viewModel.deleteRunProfile(projectId, it.id) },
            onCreate = { editingProfile = newBashRunProfile(projectId) },
            onDismiss = { showRunProfiles = false },
        )
    }
    editingProfile?.let { profile ->
        RunProfileEditorSheet(
            initial = profile,
            onSave = { updated ->
                viewModel.upsertRunProfile(updated)
                editingProfile = null
            },
            onDismiss = { editingProfile = null },
        )
    }

    if (showTodoSheet) {
        ThreadTodoSheet(
            threadTitle = session?.title?.ifBlank { "Thread" } ?: "Thread",
            todos = todos.orEmpty(),
            summary = threadSummary,
            onDismiss = { showTodoSheet = false },
        )
    }

    if (showThreadChanges) {
        ThreadChangesSheet(
            state = state,
            viewModel = viewModel,
            sessionId = resolvedId,
            onDismiss = { showThreadChanges = false },
        )
    }

    if (showBrowser) {
        val launchUrl = remember(messages, projectId, state.runTasks) {
            val texts = messages.flatMap { msg -> msg.blocks.mapNotNull { it.text } }
            val taskTexts = projectId?.let { id ->
                state.runTasksFor(id).flatMap { task ->
                    listOfNotNull(task.commandPreview.takeIf { it.isNotBlank() }, task.terminalOutputTail)
                }
            }.orEmpty()
            BrowserUrlDetector.detect(texts + taskTexts)
        }
        androidx.compose.ui.window.Dialog(
            onDismissRequest = { showBrowser = false },
            properties = androidx.compose.ui.window.DialogProperties(
                usePlatformDefaultWidth = false,
                dismissOnBackPress = true,
                dismissOnClickOutside = false,
            ),
        ) {
            InAppBrowserScreen(
                initialUrl = launchUrl,
                proxyInfo = state.desktopWebProxy,
                onDismiss = { showBrowser = false },
            )
        }
    }
}

/**
 * One message row. User messages render as a colored bubble aligned right
 * (mirrors iOS); assistant messages render as plain text aligned left, with
 * no surrounding container — matching iOS where Claude's reply flows as
 * inline content rather than a chat bubble.
 */
@Composable
private fun MessageBubble(
    msg: ChatMessage,
    sessionId: String,
    pendingQuestions: List<PendingQuestionPayload>,
    onToolCallClick: (ToolCall) -> Unit,
    onQuestionClick: (PendingQuestionPayload) -> Unit,
    onEditDetailsClick: (EditPreviewData) -> Unit,
) {
    val isUser = msg.role == Role.USER
    if (isUser) {
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.End,
        ) {
            Surface(
                color = MaterialTheme.colorScheme.primaryContainer,
                contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                shape = RoundedCornerShape(18.dp),
                modifier = Modifier.widthIn(max = 320.dp),
            ) {
                Column(Modifier.padding(horizontal = 14.dp, vertical = 10.dp)) {
                    if (msg.textContent.isNotEmpty()) {
                        // User-typed messages are plain text — no need to
                        // render markdown for what the user just typed.
                        Text(msg.textContent, style = MaterialTheme.typography.bodyMedium)
                    }
                }
            }
        }
    } else {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(end = 24.dp, start = 4.dp, top = 2.dp, bottom = 2.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            assistantRenderBlocks(msg).forEach { block ->
                when (block) {
                    is AssistantRenderBlock.Text -> {
                        MarkdownWithCode(
                            markdown = block.text,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                    }
                    is AssistantRenderBlock.Tool -> {
                        val toolCall = block.toolCall
                        when {
                            toolCall.isAskUserQuestion() -> {
                                QuestionToolCard(
                                    toolCall = toolCall,
                                    onClick = {
                                        val pending = toolCall.pendingQuestionPayload(sessionId, pendingQuestions)
                                        if (pending != null) {
                                            onQuestionClick(pending)
                                        } else {
                                            onToolCallClick(toolCall)
                                        }
                                    },
                                )
                            }
                            toolCall.editPreviewData() != null -> {
                                EditToolCard(
                                    toolCall = toolCall,
                                    onShowDetails = { preview -> onEditDetailsClick(preview) },
                                )
                            }
                            else -> {
                                ToolCallChip(toolCall = toolCall, onClick = { onToolCallClick(toolCall) })
                            }
                        }
                    }
                    is AssistantRenderBlock.TransientTools -> {
                        TransientToolGroup(
                            groupId = block.id,
                            tools = block.tools,
                            onToolCallClick = onToolCallClick,
                        )
                    }
                }
            }
        }
    }
}

private sealed interface AssistantRenderBlock {
    val id: String

    data class Text(override val id: String, val text: String) : AssistantRenderBlock
    data class Tool(val toolCall: ToolCall) : AssistantRenderBlock {
        override val id: String = "tool-${toolCall.id}"
    }
    data class TransientTools(override val id: String, val tools: List<ToolCall>) : AssistantRenderBlock
}

private fun assistantRenderBlocks(message: ChatMessage): List<AssistantRenderBlock> {
    val result = mutableListOf<AssistantRenderBlock>()
    val pendingTransientTools = mutableListOf<ToolCall>()
    var pendingTransientGroupStartId: String? = null

    fun flushTransientTools() {
        if (pendingTransientTools.isEmpty()) return
        val startId = pendingTransientGroupStartId ?: pendingTransientTools.first().id
        result += AssistantRenderBlock.TransientTools(
            id = "transient-tools-$startId-${pendingTransientTools.size}",
            tools = pendingTransientTools.toList(),
        )
        pendingTransientTools.clear()
        pendingTransientGroupStartId = null
    }

    fun appendText(block: MessageBlock) {
        val text = block.text?.takeIf { it.isNotEmpty() } ?: return
        val lastIndex = result.lastIndex
        if (lastIndex >= 0 && result[lastIndex] is AssistantRenderBlock.Text) {
            val previous = result[lastIndex] as AssistantRenderBlock.Text
            val needsSpace = previous.text.lastOrNull()?.isWhitespace() != true &&
                text.firstOrNull()?.isWhitespace() != true
            result[lastIndex] = previous.copy(text = previous.text + if (needsSpace) " $text" else text)
        } else {
            result += AssistantRenderBlock.Text(id = block.id, text = text)
        }
    }

    message.blocks.forEach { block ->
        val text = block.text
        if (!text.isNullOrEmpty()) {
            flushTransientTools()
            appendText(block)
            return@forEach
        }

        val toolCall = block.toolCall ?: return@forEach
        if (message.isStreaming) {
            flushTransientTools()
            result += AssistantRenderBlock.Tool(toolCall)
            return@forEach
        }

        if (toolCall.isTransientTool()) {
            if (toolCall.result != null || toolCall.isError) {
                if (pendingTransientGroupStartId == null) {
                    pendingTransientGroupStartId = toolCall.id
                }
                pendingTransientTools += toolCall
            }
            return@forEach
        }

        if (toolCall.result != null || toolCall.isError || toolCall.isKeepAlways()) {
            flushTransientTools()
            result += AssistantRenderBlock.Tool(toolCall)
        }
    }

    flushTransientTools()
    return result
}

@Composable
private fun ToolCallChip(toolCall: ToolCall, onClick: () -> Unit) {
    AssistChip(
        onClick = onClick,
        label = { Text(toolCall.displayName()) },
        leadingIcon = {
            Icon(
                toolCall.icon(),
                contentDescription = null,
                modifier = Modifier.size(16.dp),
            )
        },
    )
}

@Composable
private fun TransientToolGroup(
    groupId: String,
    tools: List<ToolCall>,
    onToolCallClick: (ToolCall) -> Unit,
) {
    var expanded by remember(groupId) { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Surface(
            modifier = Modifier
                .fillMaxWidth()
                .clickable { expanded = !expanded },
            shape = RoundedCornerShape(12.dp),
            color = MaterialTheme.colorScheme.surfaceContainerLow,
        ) {
            Row(
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(
                    Icons.Outlined.Build,
                    contentDescription = null,
                    modifier = Modifier.size(16.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(
                    "${tools.size} ${if (tools.size == 1) "tool" else "tools"} executed",
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f),
                )
                Icon(
                    Icons.Outlined.ExpandMore,
                    contentDescription = if (expanded) "Collapse tools" else "Expand tools",
                    modifier = Modifier.size(18.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        if (expanded) {
            Column(
                modifier = Modifier.padding(start = 12.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                tools.forEach { toolCall ->
                    ToolCallChip(toolCall = toolCall, onClick = { onToolCallClick(toolCall) })
                }
            }
        }
    }
}

@Composable
private fun QuestionToolCard(toolCall: ToolCall, onClick: () -> Unit) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick),
        shape = RoundedCornerShape(14.dp),
        color = MaterialTheme.colorScheme.secondaryContainer,
        contentColor = MaterialTheme.colorScheme.onSecondaryContainer,
    ) {
        Row(
            modifier = Modifier.padding(14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(Icons.Outlined.QuestionAnswer, contentDescription = null, modifier = Modifier.size(20.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text("Question", style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold)
                Text(
                    toolCall.questionSummary(),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSecondaryContainer.copy(alpha = 0.78f),
                    maxLines = 2,
                )
            }
        }
    }
}

@Composable
private fun EditToolCard(toolCall: ToolCall, onShowDetails: (EditPreviewData) -> Unit) {
    val preview = toolCall.editPreviewData() ?: return
    var expanded by remember(toolCall.id) { mutableStateOf(false) }
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(14.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
    ) {
        Column {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable {
                        if (preview.diffs.isEmpty()) {
                            onShowDetails(preview)
                        } else {
                            expanded = !expanded
                        }
                    }
                    .padding(horizontal = 14.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Icon(
                    if (toolCall.isError) Icons.Outlined.ErrorOutline else Icons.Outlined.Edit,
                    contentDescription = null,
                    modifier = Modifier.size(18.dp),
                    tint = if (toolCall.isError) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary,
                )
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        preview.title,
                        style = MaterialTheme.typography.labelLarge,
                        fontWeight = FontWeight.SemiBold,
                    )
                    preview.subtitle?.let { subtitle ->
                        Text(
                            subtitle,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                        )
                    }
                }
                Icon(
                    Icons.Outlined.ExpandMore,
                    contentDescription = if (expanded) "Collapse edit" else "Expand edit",
                    modifier = Modifier.size(18.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (expanded) {
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                Column(
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    preview.diffs.forEach { diff ->
                        FileDiffPreview(diff)
                    }
                    TextButton(
                        onClick = { onShowDetails(preview) },
                        modifier = Modifier.align(Alignment.End),
                    ) {
                        Text("Details")
                    }
                }
            }
        }
    }
}

@Composable
private fun FileDiffPreview(diff: FileDiffData) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (diff.path.isNotBlank()) {
            Text(
                diff.path.substringAfterLast('/'),
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        val scrollState = rememberScrollState()
        Surface(
            shape = RoundedCornerShape(10.dp),
            color = MaterialTheme.colorScheme.surface,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(
                modifier = Modifier
                    .horizontalScroll(scrollState)
                    .padding(vertical = 6.dp),
            ) {
                diff.inlineVisibleLines().forEach { line ->
                    DiffLine(line)
                }
                if (diff.isTruncatedAtInline) {
                    Text(
                        "…",
                        style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 10.dp, vertical = 2.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun DiffLine(line: String) {
    val isAddition = line.startsWith("+") && !line.startsWith("+++")
    val isRemoval = line.startsWith("-") && !line.startsWith("---")
    val isHunk = line.startsWith("@@")
    val background = when {
        isAddition -> Color(0xFF2E7D32).copy(alpha = 0.12f)
        isRemoval -> Color(0xFFC62828).copy(alpha = 0.12f)
        isHunk -> MaterialTheme.colorScheme.primary.copy(alpha = 0.10f)
        else -> Color.Transparent
    }
    val foreground = when {
        isAddition -> Color(0xFF2E7D32)
        isRemoval -> Color(0xFFC62828)
        isHunk -> MaterialTheme.colorScheme.primary
        else -> MaterialTheme.colorScheme.onSurface
    }
    Text(
        line.ifEmpty { " " },
        style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
        color = foreground,
        modifier = Modifier
            .fillMaxWidth()
            .background(background)
            .padding(horizontal = 10.dp, vertical = 1.dp),
    )
}

private fun ToolCall.isAskUserQuestion(): Boolean =
    name.equals("AskUserQuestion", ignoreCase = true)

private fun ToolCall.pendingQuestionPayload(
    sessionId: String,
    pendingQuestions: List<PendingQuestionPayload>,
): PendingQuestionPayload? {
    if (result != null) return null
    return pendingQuestions.firstOrNull { it.toolUseID == id }
        ?: PendingQuestionPayload(
            toolUseID = id,
            sessionID = sessionId,
            toolInputJSON = compactJson.encodeToString(JsonObject.serializer(), input),
        )
}

private fun ToolCall.questionSummary(): String {
    val rawQuestions = input.arrayValue("questions")
    val first = (rawQuestions.firstOrNull() as? JsonObject)?.stringValue("question")
    return first?.takeIf { it.isNotBlank() } ?: "Answer requested by the agent"
}

private fun ToolCall.isTransientTool(): Boolean {
    return when (name.normalizedToolName()) {
        "read", "glob", "grep", "list", "search", "bash", "execute" -> true
        else -> false
    }
}

private fun ToolCall.isKeepAlways(): Boolean =
    isAskUserQuestion() || isFileModificationTool()

private fun ToolCall.displayName(): String = displayToolName()

private fun ToolCall.icon(): ImageVector {
    return when {
        isError -> Icons.Outlined.ErrorOutline
        isFileModificationTool() -> Icons.Outlined.Edit
        isAskUserQuestion() -> Icons.Outlined.QuestionAnswer
        else -> Icons.Outlined.Build
    }
}

@Composable
private fun StreamingIndicator(thinking: Boolean) {
    Surface(
        shape = RoundedCornerShape(20.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        modifier = Modifier.padding(start = 4.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
        ) {
            TypingDots()
            Text(
                if (thinking) "Thinking…" else "Streaming…",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun ThreadLoadingOverlay() {
    val transition = rememberInfiniteTransition(label = "thread-loading")
    val pulse by transition.animateFloat(
        initialValue = 0.55f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 900),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "thread-loading-pulse",
    )
    val skeletonColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f + (pulse * 0.04f))

    Surface(
        modifier = Modifier.fillMaxSize(),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.96f),
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 16.dp, vertical = 18.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Surface(
                shape = RoundedCornerShape(22.dp),
                color = MaterialTheme.colorScheme.surfaceContainerHigh,
                tonalElevation = 2.dp,
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 9.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(22.dp),
                        strokeWidth = 2.5.dp,
                    )
                    Text(
                        "Loading thread",
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                }
            }

            Spacer(Modifier.height(34.dp))

            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .widthIn(max = 420.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                ThreadLoadingBubble(
                    widthFraction = 0.86f,
                    alignEnd = false,
                    rows = listOf(0.62f, 0.94f, 0.72f),
                    color = skeletonColor,
                )
                ThreadLoadingBubble(
                    widthFraction = 0.64f,
                    alignEnd = true,
                    rows = listOf(0.88f, 0.52f),
                    color = skeletonColor,
                )
                ThreadLoadingBubble(
                    widthFraction = 0.9f,
                    alignEnd = false,
                    rows = listOf(0.46f, 0.98f, 0.82f, 0.58f),
                    color = skeletonColor,
                )
            }

            Spacer(Modifier.weight(1f))

            ThreadLoadingComposer(color = skeletonColor)
        }
    }
}

@Composable
private fun ThreadLoadingBubble(
    widthFraction: Float,
    alignEnd: Boolean,
    rows: List<Float>,
    color: Color,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = if (alignEnd) Arrangement.End else Arrangement.Start,
    ) {
        Surface(
            modifier = Modifier.fillMaxWidth(widthFraction),
            shape = RoundedCornerShape(18.dp),
            color = MaterialTheme.colorScheme.surfaceContainerHighest.copy(alpha = 0.58f),
        ) {
            Column(
                modifier = Modifier.padding(horizontal = 14.dp, vertical = 13.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                rows.forEach { rowWidth ->
                    Box(
                        Modifier
                            .fillMaxWidth(rowWidth)
                            .height(10.dp)
                            .background(color, RoundedCornerShape(5.dp)),
                    )
                }
            }
        }
    }
}

@Composable
private fun ThreadLoadingComposer(color: Color) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .widthIn(max = 420.dp),
        shape = RoundedCornerShape(24.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        tonalElevation = 2.dp,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Box(
                Modifier
                    .weight(1f)
                    .height(14.dp)
                    .background(color, RoundedCornerShape(7.dp)),
            )
            Surface(
                modifier = Modifier.size(34.dp),
                shape = RoundedCornerShape(17.dp),
                color = MaterialTheme.colorScheme.primary.copy(alpha = 0.18f),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(
                        Icons.AutoMirrored.Outlined.Send,
                        contentDescription = null,
                        modifier = Modifier.size(16.dp),
                        tint = MaterialTheme.colorScheme.primary.copy(alpha = 0.75f),
                    )
                }
            }
        }
    }
}

/**
 * Three bouncing dots used inside [StreamingIndicator]. Each dot animates its
 * alpha and vertical offset with an `InfiniteTransition` staggered by 150ms,
 * giving the familiar iMessage-style "agent is typing" look that matches the
 * iOS streaming indicator more closely than a spinning circle.
 */
@Composable
private fun TypingDots() {
    val transition = androidx.compose.animation.core.rememberInfiniteTransition(label = "dots")
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
        listOf(0, 150, 300).forEach { delayMs ->
            val alpha by transition.animateFloat(
                initialValue = 0.3f,
                targetValue = 1f,
                animationSpec = androidx.compose.animation.core.infiniteRepeatable(
                    animation = androidx.compose.animation.core.tween(
                        durationMillis = 600,
                        delayMillis = delayMs,
                        easing = androidx.compose.animation.core.FastOutSlowInEasing,
                    ),
                    repeatMode = androidx.compose.animation.core.RepeatMode.Reverse,
                ),
                label = "dot-$delayMs",
            )
            Box(
                Modifier
                    .size(6.dp)
                    .background(
                        MaterialTheme.colorScheme.primary.copy(alpha = alpha),
                        androidx.compose.foundation.shape.CircleShape,
                    )
            )
        }
    }
}

@Composable
private fun Composer(isStreaming: Boolean, onSend: (String) -> Unit, onCancel: () -> Unit) {
    var text by remember { mutableStateOf("") }
    Surface(
        tonalElevation = 2.dp,
        modifier = Modifier
            .fillMaxWidth()
            .imePadding()
            .navigationBarsPadding(),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TextField(
                value = text,
                onValueChange = { text = it },
                modifier = Modifier
                    .weight(1f)
                    .heightIn(min = 48.dp),
                maxLines = 6,
                placeholder = { Text("Message…") },
                shape = RoundedCornerShape(24.dp),
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHighest,
                    unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHighest,
                    disabledContainerColor = MaterialTheme.colorScheme.surfaceContainerHighest,
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent,
                    disabledIndicatorColor = Color.Transparent,
                    focusedPlaceholderColor = MaterialTheme.colorScheme.onSurfaceVariant,
                    unfocusedPlaceholderColor = MaterialTheme.colorScheme.onSurfaceVariant,
                ),
            )
            Spacer(Modifier.width(8.dp))
            if (isStreaming) {
                FilledIconButton(
                    onClick = onCancel,
                    modifier = Modifier.size(44.dp),
                ) {
                    Icon(
                        Icons.Outlined.Close,
                        contentDescription = "Stop",
                        modifier = Modifier.size(20.dp),
                    )
                }
            } else {
                FilledIconButton(
                    onClick = {
                        val trimmed = text.trim()
                        if (trimmed.isNotEmpty()) {
                            onSend(trimmed)
                            text = ""
                        }
                    },
                    enabled = text.isNotBlank(),
                    modifier = Modifier.size(44.dp),
                ) {
                    Icon(
                        Icons.AutoMirrored.Outlined.Send,
                        contentDescription = "Send",
                        modifier = Modifier.size(20.dp),
                    )
                }
            }
        }
    }
}

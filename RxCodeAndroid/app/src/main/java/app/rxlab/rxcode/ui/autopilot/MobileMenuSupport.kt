package app.rxlab.rxcode.ui.autopilot

import android.net.Uri
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.MergeType
import androidx.compose.material.icons.outlined.Book
import androidx.compose.material.icons.outlined.Build
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material.icons.outlined.RateReview
import androidx.compose.material.icons.outlined.Sell
import androidx.compose.material.icons.outlined.StopCircle
import androidx.compose.material.icons.outlined.Sync
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import app.rxlab.rxcode.proto.MenuAction
import app.rxlab.rxcode.proto.MenuCommandKind
import app.rxlab.rxcode.proto.MenuItem
import app.rxlab.rxcode.proto.MenuItemKind
import app.rxlab.rxcode.proto.MenuItemRole

/**
 * Shared rendering helpers for the desktop's serialized context menu on Android.
 * The menu items themselves are the single source of truth (built by desktop
 * hooks); these only translate the cross-platform identifiers into Android
 * presentation — the SF Symbol → Material icon mapping, the deep-link → on-device
 * target mapping (mirroring iOS `mobileMenuDeepLinkTarget`), and the loading
 * dialog copy for an async command.
 */

/** The on-device UI a menu deep link should open, or [None] when it has no Android equivalent. */
sealed interface MobileMenuDeepLinkTarget {
    data object SecretsDownload : MobileMenuDeepLinkTarget
    data object ReleaseCreate : MobileMenuDeepLinkTarget
    /** Open a new on-device setup chat prefilled with [prompt]. */
    data class SetupChat(val prompt: String) : MobileMenuDeepLinkTarget
    data object None : MobileMenuDeepLinkTarget
}

private const val SECRETS_SETUP_PROMPT =
    "Set up encrypted secrets for this repository so I can sync environment files securely."
private const val DOCS_SETUP_PROMPT =
    "Set up documentation publishing for this repository so its docs are indexed into RxCode docs search."
private const val RELEASE_SETUP_PROMPT =
    "Set up a release workflow for this repository (semantic-release + a GitHub Actions release workflow)."
private const val CI_SETUP_PROMPT =
    "Set up CI auto-update for this repository so failing CI is fixed automatically."

/**
 * Map a `rxcode://menu/<action>?…` deep link to the matching on-device target.
 * Mirrors iOS `mobileMenuDeepLinkTarget`; docs-search and unknown actions have no
 * on-device sheet and resolve to [MobileMenuDeepLinkTarget.None].
 */
fun mobileMenuDeepLinkTarget(url: String): MobileMenuDeepLinkTarget {
    val uri = runCatching { Uri.parse(url) }.getOrNull() ?: return MobileMenuDeepLinkTarget.None
    if (uri.scheme != "rxcode" || uri.host != "menu") return MobileMenuDeepLinkTarget.None
    val action = uri.path?.trimStart('/').orEmpty()
    return when (action) {
        "secrets-download" -> MobileMenuDeepLinkTarget.SecretsDownload
        "release-create" -> MobileMenuDeepLinkTarget.ReleaseCreate
        "secrets-setup" -> MobileMenuDeepLinkTarget.SetupChat(SECRETS_SETUP_PROMPT)
        "docs-setup" -> MobileMenuDeepLinkTarget.SetupChat(DOCS_SETUP_PROMPT)
        "release-setup" -> MobileMenuDeepLinkTarget.SetupChat(RELEASE_SETUP_PROMPT)
        "ci-setup" -> MobileMenuDeepLinkTarget.SetupChat(CI_SETUP_PROMPT)
        else -> MobileMenuDeepLinkTarget.None
    }
}

/** Material icon for a desktop SF Symbol name, or null to render no leading icon. */
fun menuItemIcon(systemImage: String?): ImageVector? = when (systemImage) {
    "checklist" -> Icons.Outlined.RateReview
    "checkmark.circle" -> Icons.Outlined.CheckCircle
    "arrow.triangle.pull" -> Icons.AutoMirrored.Outlined.MergeType
    "wrench.and.screwdriver" -> Icons.Outlined.Build
    "stop.circle" -> Icons.Outlined.StopCircle
    "key.fill" -> Icons.Outlined.Key
    "tag.fill" -> Icons.Outlined.Sell
    "books.vertical.fill" -> Icons.Outlined.Book
    "arrow.triangle.2.circlepath" -> Icons.Outlined.Sync
    else -> null
}

/**
 * Loading dialog copy (title to message) shown while an `isAsync` command runs.
 * Only Create PR is async today; the generic fallback covers any future ones.
 */
fun commandLoadingText(kind: MenuCommandKind): Pair<String, String> = when (kind) {
    MenuCommandKind.PROJECT_CREATE_PULL_REQUEST ->
        "Creating Pull Request…" to "The Mac is pushing the branch and opening the PR."
    else ->
        "Working…" to "The Mac is performing the requested action."
}

/**
 * Renders the desktop's serialized [MenuItem]s as dropdown rows: separators as
 * dividers, leaf items as tappable rows (with the desktop's destructive role and
 * disabled state honored), and — defensively — submenu children flattened inline
 * (the project/thread menus the desktop ships are flat today). Shared by the
 * project menu and the per-thread menus so every surface renders identically.
 */
@Composable
fun ColumnScope.SerializedMenuItems(
    items: List<MenuItem>,
    onAction: (MenuAction?) -> Unit,
) {
    items.forEach { item ->
        when (item.kind) {
            MenuItemKind.SEPARATOR -> HorizontalDivider()
            MenuItemKind.ITEM -> {
                val children = item.children
                if (!children.isNullOrEmpty()) {
                    SerializedMenuItems(children, onAction)
                } else {
                    val icon = menuItemIcon(item.systemImage)
                    val isDestructive = item.role == MenuItemRole.DESTRUCTIVE
                    DropdownMenuItem(
                        text = {
                            Text(
                                item.title,
                                color = if (isDestructive) MaterialTheme.colorScheme.error else Color.Unspecified,
                            )
                        },
                        leadingIcon = icon?.let {
                            {
                                Icon(
                                    it,
                                    contentDescription = null,
                                    tint = if (isDestructive) MaterialTheme.colorScheme.error else LocalContentColor.current,
                                )
                            }
                        },
                        enabled = !item.isDisabled,
                        onClick = { onAction(item.action) },
                    )
                }
            }
        }
    }
}

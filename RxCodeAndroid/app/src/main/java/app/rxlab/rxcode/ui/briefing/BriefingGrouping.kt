package app.rxlab.rxcode.ui.briefing

import app.rxlab.rxcode.proto.MobileBranchBriefing
import app.rxlab.rxcode.proto.MobileThreadSummary
import java.time.Instant
import java.util.UUID

/**
 * Same key shape iOS uses: `{ projectId, branch }`. Stable identifier for a
 * single briefing card and for selection in the tablet pane layout.
 */
data class BriefingGroupKey(val projectId: UUID, val branch: String) {
    val id: String get() = "$projectId::$branch"
}

/**
 * One project+branch row, paired with whatever briefing text and thread cards
 * the desktop sent for it. Mirrors Swift `GroupedBriefing`.
 */
data class GroupedBriefing(
    val projectId: UUID,
    val branch: String,
    val briefing: MobileBranchBriefing?,
    val threads: List<MobileThreadSummary>,
    val updatedAt: Instant,
) {
    val id: String get() = "$projectId::$branch"
    val key: BriefingGroupKey get() = BriefingGroupKey(projectId, branch)
}

/**
 * Combine the desktop's per-branch briefings with the per-thread summaries
 * into one card per (project, branch). `updatedAt` is the most recent of
 * either source so cards stay sorted by activity. Mirrors Swift
 * `groupBriefings(briefings:threads:)`.
 */
fun groupBriefings(
    briefings: List<MobileBranchBriefing>,
    threads: List<MobileThreadSummary>,
): List<GroupedBriefing> {
    val buckets = HashMap<String, GroupedBriefing>()

    for (briefing in briefings) {
        val key = "${briefing.projectId}::${briefing.branch}"
        val existing = buckets[key]
        buckets[key] = GroupedBriefing(
            projectId = briefing.projectId,
            branch = briefing.branch,
            briefing = briefing,
            threads = existing?.threads ?: emptyList(),
            updatedAt = maxOf(briefing.updatedAt, existing?.updatedAt ?: Instant.EPOCH),
        )
    }

    for (thread in threads) {
        val key = "${thread.projectId}::${thread.branch}"
        val existing = buckets[key]
        val mergedThreads = (existing?.threads.orEmpty() + thread)
            .sortedByDescending { it.updatedAt }
        buckets[key] = GroupedBriefing(
            projectId = thread.projectId,
            branch = thread.branch,
            briefing = existing?.briefing,
            threads = mergedThreads,
            updatedAt = maxOf(thread.updatedAt, existing?.updatedAt ?: Instant.EPOCH),
        )
    }

    return buckets.values.sortedByDescending { it.updatedAt }
}

/**
 * Reorder briefing groups to follow the sidebar project order (the order of
 * [projectIds]). Groups whose project isn't listed sort last; within the same
 * project the most recently updated comes first. Mirrors the desktop
 * `BriefingView` sort and Swift `sortedByProjectOrder`.
 */
fun List<GroupedBriefing>.sortedByProjectOrder(
    projectIds: List<UUID>,
): List<GroupedBriefing> {
    val order = projectIds.withIndex().associate { (index, id) -> id to index }
    return sortedWith(
        compareBy<GroupedBriefing> { order[it.projectId] ?: Int.MAX_VALUE }
            .thenByDescending { it.updatedAt }
    )
}

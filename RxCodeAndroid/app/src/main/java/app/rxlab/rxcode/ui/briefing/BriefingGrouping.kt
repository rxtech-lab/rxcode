package app.rxlab.rxcode.ui.briefing

import app.rxlab.rxcode.proto.CodingPlanActivity
import app.rxlab.rxcode.proto.MobileBranchBriefing
import app.rxlab.rxcode.proto.MobileThreadSummary
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.UUID

data class BriefingGroupKey(val projectId: UUID, val branch: String, val day: LocalDate) {
    val id: String get() = "$projectId::$branch::$day"
}

data class GroupedBriefing(
    val key: BriefingGroupKey,
    val briefing: MobileBranchBriefing?,
    val threads: List<MobileThreadSummary>,
    val plans: List<CodingPlanActivity>,
    val updatedAt: Instant,
) {
    val id get() = key.id
    val projectId get() = key.projectId
    val branch get() = key.branch
}

/** Group plan activity and summaries on the same local calendar days as the iOS timeline. */
fun groupBriefings(
    briefings: List<MobileBranchBriefing>,
    threads: List<MobileThreadSummary>,
    plans: List<CodingPlanActivity> = emptyList(),
    zone: ZoneId = ZoneId.systemDefault(),
): List<GroupedBriefing> {
    fun key(project: UUID, branch: String, timestamp: Instant) =
        BriefingGroupKey(project, branch, timestamp.atZone(zone).toLocalDate())

    val daily = briefings.groupBy { key(it.projectId, it.branch, it.day ?: it.updatedAt) }
    val chats = threads.groupBy { key(it.projectId, it.branch, it.createdAt ?: it.updatedAt) }
    val activities = plans.groupBy { key(it.projectID, it.branch ?: "unknown", it.updatedAt) }

    return (daily.keys + chats.keys + activities.keys).map { day ->
        // A legacy, branch-wide record can share the day of a dated briefing.
        val briefing = daily[day]?.maxWithOrNull(compareBy<MobileBranchBriefing> { it.day != null }.thenBy { it.updatedAt })
        val dayThreads = chats[day].orEmpty().sortedByDescending { it.updatedAt }
        val dayPlans = activities[day].orEmpty().sortedByDescending { it.updatedAt }
        val updated = listOfNotNull(briefing?.updatedAt, dayThreads.firstOrNull()?.updatedAt, dayPlans.firstOrNull()?.updatedAt).max()
        GroupedBriefing(day, briefing, dayThreads, dayPlans, updated)
    }.sortedByDescending { it.updatedAt }
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

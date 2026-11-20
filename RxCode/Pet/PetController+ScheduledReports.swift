import Foundation

extension PetController {
    /// Register a durable outbox item once. This never opens capture or starts a voice session.
    func deliverScheduledReport(id: UUID, title: String, text: String, acknowledge: @escaping @MainActor () async -> Void) {
        guard configuration.isEnabled, configuration.proactiveMode != .off else { return }
        let captionOnly = isMuted || configuration.proactiveMode == .bubbleOnly
        if scheduledReportDeliveries[id] != nil {
            if captionOnly {
                showBubble(.init(title: title, text: text, isProactive: true, action: nil), duration: 20)
                if let speechID = scheduledReportDeliveries[id]?.speechID { removeQueuedSpeech(ids: [speechID]) }
                Task { await acknowledgeScheduledReports(ids: [id]) }
            } else { startAnnouncementDeliveryIfNeeded() }
            return
        }
        showBubble(.init(title: title, text: text, isProactive: true, action: nil), duration: 20)
        if captionOnly {
            scheduledReportDeliveries[id] = (text, nil, acknowledge)
            Task { await acknowledgeScheduledReports(ids: [id]) }
        } else {
            let speechID = speakProactivelyOrQueue(text)
            scheduledReportDeliveries[id] = (text, speechID, acknowledge)
        }
    }

    func cancelScheduledReport(id: UUID) {
        if let entry = scheduledReportDeliveries.removeValue(forKey: id), let speechID = entry.speechID {
            removeQueuedSpeech(ids: [speechID])
        }
    }

    func acknowledgeScheduledReports(speechIDs: [UUID]) async {
        let ids: [UUID] = scheduledReportDeliveries.compactMap { id, entry in
            guard let speechID = entry.speechID, speechIDs.contains(speechID) else { return nil }
            return id
        }
        await acknowledgeScheduledReports(ids: ids)
    }

    func acknowledgeScheduledReports(ids: [UUID]) async {
        for id in ids {
            guard let delivery = scheduledReportDeliveries.removeValue(forKey: id) else { continue }
            await delivery.acknowledge()
        }
    }
}

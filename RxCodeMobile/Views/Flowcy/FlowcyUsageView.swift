import RxCodeCore
import SwiftUI

/// Account plan and metered usage from Flowcy (`subscriptions`, `agent/usage`,
/// `notifications/usage`). Purchases stay on the website; this page only reads.
struct FlowcyUsageView: View {
    @State private var plan: FlowcyPlan?
    @State private var agent: FlowcyUsageSection<[FlowcyUsageMeter]> = .loading
    @State private var notifications: FlowcyUsageSection<FlowcyUsageMeter> = .loading
    @State private var account: FlowcyUsageSection<FlowcyAccountUsage> = .loading
    @State private var planError: String?
    @State private var loadedOnce = false
    @State private var reloadID = UUID()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                planCard
                section("AI Sessions", subtitle: "Agent sessions in this billing period.") {
                    sessionContent
                }
                section("Agent Spend", subtitle: "AI cost across rolling windows, including pending requests.") {
                    agentContent
                }
                section("Features", subtitle: "Allowances for automation and release tools.") {
                    featureContent
                }
                section("Notifications", subtitle: "Messages sent today (UTC).") {
                    notificationContent
                }
                section("Storage", subtitle: "Release files kept for downloads. Older files are removed when full.") {
                    storageContent
                }
                Label("To change your plan or payment details, sign in to your Flowcy account in a web browser.",
                      systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .padding()
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(MobileCard.pageBackground)
        .navigationTitle("Usage")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .overlay {
            if !loadedOnce {
                ProgressView("Loading usage…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    MobileHaptics.buttonTap()
                    reloadID = UUID()
                }
            }
        }
        .task(id: reloadID) { await load() }
    }

    // MARK: Plan

    private var planCard: some View {
        HStack(alignment: .center, spacing: 14) {
            MobileCardIconTile(systemImage: plan?.isPaid == true ? "sparkles" : "person.crop.circle",
                               tint: plan?.isPaid == true ? ClaudeTheme.accent : .secondary, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text("Current Plan").font(.caption).foregroundStyle(.secondary)
                Text(plan?.title ?? (planError == nil ? "Loading…" : "Unavailable"))
                    .font(.title3.weight(.semibold))
                if let detail = plan?.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                } else if let planError {
                    Text(planError).font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let plan {
                MobileCardTag(text: plan.statusLabel, tint: plan.statusTint)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mobileCardSurface()
        .accessibilityElement(children: .combine)
    }

    // MARK: Agent

    @ViewBuilder private var agentContent: some View {
        switch agent {
        case .loading:
            placeholder("Loading agent usage…")
        case .failed(let message):
            unavailable(message)
        case .loaded(let meters):
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(FlowcyUsageMeter.agentWindows, id: \.key) { window in
                    FlowcyUsageGaugeCard(title: window.title,
                                         meter: meters.first { $0.key == window.key },
                                         format: .currency)
                }
            }
        }
    }

    // MARK: Account meters

    @ViewBuilder private var sessionContent: some View {
        switch account {
        case .loading: placeholder("Loading sessions…")
        case .failed(let message): unavailable(message)
        case .loaded(let usage):
            if let sessions = usage.sessions {
                FlowcyUsageBarCard(title: "Sessions", systemImage: "bubble.left.and.text.bubble.right",
                                   meter: sessions, unit: .sessions)
            } else {
                unavailable(String(localized: "Session usage is temporarily unavailable."))
            }
        }
    }

    @ViewBuilder private var featureContent: some View {
        switch account {
        case .loading: placeholder("Loading feature usage…")
        case .failed(let message): unavailable(message)
        case .loaded(let usage):
            let items = usage.features
            if items.isEmpty {
                unavailable(String(localized: "Feature usage is temporarily unavailable."))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(items, id: \.key) { item in
                        FlowcyUsageTile(title: item.title, systemImage: item.systemImage, meter: item.meter)
                    }
                }
            }
        }
    }

    @ViewBuilder private var storageContent: some View {
        switch account {
        case .loading: placeholder("Loading storage…")
        case .failed(let message): unavailable(message)
        case .loaded(let usage):
            if let storage = usage.storage {
                FlowcyUsageBarCard(title: "Release files", systemImage: "externaldrive", meter: storage, unit: .bytes)
            } else {
                unavailable(String(localized: "Storage usage is temporarily unavailable."))
            }
        }
    }

    // MARK: Notifications

    @ViewBuilder private var notificationContent: some View {
        switch notifications {
        case .loading:
            placeholder("Loading notification usage…")
        case .failed(let message):
            unavailable(message)
        case .loaded(let meter):
            FlowcyUsageBarCard(title: "Sent today", systemImage: "bell.badge", meter: meter, unit: .notifications)
        }
    }

    // MARK: Building blocks

    private func section<Content: View>(_ title: LocalizedStringKey, subtitle: LocalizedStringKey,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            content()
        }
    }

    private func placeholder(_ text: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mobileCardSurface()
    }

    private func unavailable(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            MobileCardIconTile(systemImage: "exclamationmark.triangle", tint: .orange, size: 32)
            VStack(alignment: .leading, spacing: 6) {
                Text(message).font(.subheadline).foregroundStyle(.secondary)
                Button("Retry") {
                    MobileHaptics.buttonTap()
                    reloadID = UUID()
                }
                .font(.subheadline.weight(.semibold))
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mobileCardSurface()
    }

    // MARK: Loading

    private func fetch(_ path: String) async -> Result<JSONValue, Error> {
        do { return .success(try await FlowcyAPI().read(path)) } catch { return .failure(error) }
    }

    private func load() async {
        async let planResult = fetch("subscriptions")
        async let agentResult = fetch("agent/usage")
        async let notificationResult = fetch("notifications/usage")
        async let accountResult = fetch("usage")
        let (planValue, agentValue, notificationValue, accountValue) = await (planResult, agentResult, notificationResult, accountResult)
        // A cancelled refresh keeps what is on screen instead of reporting "cancelled".
        guard !Task.isCancelled else { return }

        switch planValue {
        case .success(let value):
            plan = value.isNull ? nil : FlowcyPlan(value)
            planError = nil
        case .failure(let error):
            if !MobileCloudState.isCancellation(error) { planError = error.localizedDescription }
        }
        switch agentValue {
        case .success(let value):
            agent = .loaded((value["meters"]?.arrayValue ?? []).compactMap(FlowcyUsageMeter.init))
        case .failure(let error):
            if !MobileCloudState.isCancellation(error) {
                agent = .failed(Self.message(for: error, unavailable: "Agent usage is temporarily unavailable."))
            }
        }
        switch notificationValue {
        case .success(let value):
            if let meter = FlowcyUsageMeter(value) { notifications = .loaded(meter) }
            else { notifications = .failed(String(localized: "Notification usage is unavailable.")) }
        case .failure(let error):
            if !MobileCloudState.isCancellation(error) {
                notifications = .failed(Self.message(for: error, unavailable: "Notification usage is temporarily unavailable."))
            }
        }
        switch accountValue {
        case .success(let value):
            account = .loaded(FlowcyAccountUsage(value))
        case .failure(let error):
            if !MobileCloudState.isCancellation(error) {
                // Older Flowcy deployments do not serve the combined usage route yet.
                if case FlowcyError.transport(404) = error {
                    account = .failed(String(localized: "Detailed usage needs a newer Flowcy server."))
                } else {
                    account = .failed(Self.message(for: error, unavailable: "Usage is temporarily unavailable."))
                }
            }
        }
        loadedOnce = true
    }

    /// The billing service answers 503 while metering is unconfigured or unreachable.
    private static func message(for error: Error, unavailable: String.LocalizationValue) -> String {
        if case FlowcyError.transport(503) = error { return String(localized: unavailable) }
        return error.localizedDescription
    }
}

enum FlowcyUsageSection<Value> {
    case loading
    case loaded(Value)
    case failed(String)
}

/// `GET /api/v1/usage`: the meters the web billing page shows beyond agent spend.
struct FlowcyAccountUsage {
    struct Feature {
        let key: String
        let title: LocalizedStringKey
        let systemImage: String
        let meter: FlowcyUsageMeter?
    }

    let sessions: FlowcyUsageMeter?
    let features: [Feature]
    let storage: FlowcyUsageMeter?

    init(_ value: JSONValue) {
        sessions = value["sessions"].flatMap(FlowcyUsageMeter.init)
        let activities = value["activities"]?.arrayValue ?? []
        func activity(_ key: String) -> FlowcyUsageMeter? {
            activities.first { $0["key"]?.stringValue == key }?["meter"].flatMap(FlowcyUsageMeter.init)
        }
        let listed = Set(activities.compactMap { $0["key"]?.stringValue })
        let catalog: [(String, LocalizedStringKey, String)] = [
            ("projects", "Projects", "square.grid.2x2"),
            ("docs", "Documents", "book"),
            ("dependency_scans", "Dependency scans", "shippingbox"),
            ("ci_updates", "CI updates", "gearshape.2"),
        ]
        var features: [Feature] = catalog.filter { listed.contains($0.0) }.map { Feature(key: $0.0, title: $0.1, systemImage: $0.2, meter: activity($0.0)) }
        if let videos = value["releaseVideos"].flatMap(FlowcyUsageMeter.init) {
            features.append(Feature(key: "release_videos", title: "Release videos", systemImage: "film", meter: videos))
        }
        self.features = features
        storage = value["storage"].flatMap(FlowcyUsageMeter.init)
    }
}

struct FlowcyPlan {
    let tier: String
    let status: String
    let periodEnd: Date?
    let cancelsAtPeriodEnd: Bool

    init(_ value: JSONValue) {
        tier = value["tier"]?.stringValue ?? "free"
        status = value["status"]?.stringValue ?? "active"
        periodEnd = FlowcyUsageMeter.date(value["currentPeriodEnd"])
        cancelsAtPeriodEnd = value["cancelAtPeriodEnd"]?.boolValue ?? false
    }

    var isPaid: Bool { tier.lowercased() != "free" }
    var title: String { "Flowcy " + tier.capitalized }
    var statusLabel: String { cancelsAtPeriodEnd ? String(localized: "Cancels") : status.replacingOccurrences(of: "_", with: " ").capitalized }
    var statusTint: Color {
        if cancelsAtPeriodEnd { return .orange }
        switch status.lowercased() {
        case "active", "trialing": return .green
        case "past_due", "unpaid", "incomplete": return .orange
        default: return .secondary
        }
    }
    var detail: String? {
        guard let periodEnd else { return isPaid ? nil : String(localized: "Upgrade on the Flowcy website for higher limits.") }
        let date = periodEnd.formatted(date: .abbreviated, time: .omitted)
        return cancelsAtPeriodEnd ? String(localized: "Ends \(date)") : String(localized: "Renews \(date)")
    }
}

struct FlowcyUsageMeter {
    let key: String
    let used: Double
    /// `nil` when the allowance is unlimited.
    let limit: Double?
    let resetsAt: Date?

    static let agentWindows: [(key: String, title: LocalizedStringKey)] = [
        ("agent_cost_5h", "5 hours"), ("agent_cost_7d", "7 days"), ("agent_cost_30d", "30 days"),
    ]

    init?(_ value: JSONValue) {
        guard let used = value["used"]?.numberValue else { return nil }
        key = value["key"]?.stringValue ?? ""
        self.used = used
        // Notifications report Number.MAX_SAFE_INTEGER for "no limit".
        if let limit = value["limit"]?.numberValue, limit < 1e15 { self.limit = limit } else { limit = nil }
        resetsAt = Self.date(value["resetsAt"])
    }

    var fraction: Double {
        guard let limit else { return 0 }
        guard limit > 0 else { return 1 }
        return min(1, max(0, used / limit))
    }

    var tint: Color { fraction >= 0.9 ? .red : fraction >= 0.7 ? .orange : ClaudeTheme.accent }

    static func usd(_ micro: Double) -> String {
        (micro / 1_000_000).formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    static func date(_ value: JSONValue?) -> Date? {
        guard let text = value?.stringValue else { return nil }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// A ring gauge card for one rolling spend window.
private struct FlowcyUsageGaugeCard: View {
    enum Format { case currency }
    let title: LocalizedStringKey
    let meter: FlowcyUsageMeter?
    let format: Format

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                if let meter, meter.limit != nil {
                    Text(meter.fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(meter.tint)
                }
            }
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: meter?.fraction ?? 0)
                    .stroke(meter?.tint ?? .secondary, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.snappy, value: meter?.fraction)
                VStack(spacing: 2) {
                    Text(meter.map { FlowcyUsageMeter.usd($0.used) } ?? "—")
                        .font(.headline)
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text(limitText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 12)
            }
            .frame(width: 104, height: 104)
            .frame(maxWidth: .infinity)
            Text(resetText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mobileCardSurface()
        .accessibilityElement(children: .combine)
    }

    private var limitText: String {
        guard let meter else { return String(localized: "Not configured") }
        guard let limit = meter.limit else { return String(localized: "Unlimited") }
        return String(localized: "of \(FlowcyUsageMeter.usd(limit))")
    }

    private var resetText: String {
        guard let resetsAt = meter?.resetsAt else { return String(localized: "No reset scheduled") }
        return String(localized: "Resets \(resetsAt.formatted(.relative(presentation: .named)))")
    }
}

/// A linear progress card for count-based allowances.
enum FlowcyUsageUnit {
    case sessions, notifications, bytes

    func amount(_ value: Double) -> String {
        switch self {
        case .bytes: ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
        case .sessions, .notifications: Int(value).formatted()
        }
    }
}

private struct FlowcyUsageBarCard: View {
    let title: LocalizedStringKey
    let systemImage: String
    let meter: FlowcyUsageMeter
    var unit: FlowcyUsageUnit = .notifications

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                MobileCardIconTile(systemImage: systemImage, tint: meter.tint, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(countText).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 4)
                if meter.limit != nil {
                    Text(meter.fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(meter.tint)
                }
            }
            if meter.limit != nil {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(meter.tint)
                            .frame(width: max(8, proxy.size.width * meter.fraction))
                    }
                }
                .frame(height: 8)
                .animation(.snappy, value: meter.fraction)
            }
            if let resetsAt = meter.resetsAt {
                Text("Resets \(resetsAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mobileCardSurface()
        .accessibilityElement(children: .combine)
    }

    private var countText: String {
        let used = unit.amount(meter.used)
        guard let limit = meter.limit else {
            return unit == .notifications ? String(localized: "\(used) sent · no daily limit") : String(localized: "\(used) used · unlimited")
        }
        if unit == .sessions && limit == 0 { return String(localized: "No AI sessions on this plan") }
        return unit == .notifications ? String(localized: "\(used) of \(unit.amount(limit)) sent")
                                      : String(localized: "\(used) of \(unit.amount(limit)) used")
    }
}

/// Compact allowance tile for the feature grid.
private struct FlowcyUsageTile: View {
    let title: LocalizedStringKey
    let systemImage: String
    let meter: FlowcyUsageMeter?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                MobileCardIconTile(systemImage: systemImage, tint: meter?.tint ?? .secondary, size: 30)
                Spacer(minLength: 4)
                if let meter, meter.limit != nil {
                    Text(meter.fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(meter.tint)
                }
            }
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.85)
            Text(amountText).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    if let meter, meter.limit != nil {
                        Capsule().fill(meter.tint).frame(width: max(5, proxy.size.width * meter.fraction))
                    }
                }
            }
            .frame(height: 5)
            Text(resetText).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mobileCardSurface()
        .accessibilityElement(children: .combine)
    }

    private var amountText: String {
        guard let meter else { return String(localized: "Not configured") }
        guard let limit = meter.limit else { return String(localized: "\(Int(meter.used)) used · unlimited") }
        return String(localized: "\(Int(meter.used)) of \(Int(limit)) used")
    }

    private var resetText: String {
        guard let resetsAt = meter?.resetsAt else { return String(localized: "No reset") }
        return String(localized: "Resets \(resetsAt.formatted(.relative(presentation: .named)))")
    }
}

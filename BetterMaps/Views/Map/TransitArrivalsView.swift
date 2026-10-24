import SwiftUI
import CoreLocation

struct TransitArrivalsView: View {
    /// The stop the sheet is for; departures cover `stop.id` ∪ `stop.altIds`.
    let stop: TransitStop
    /// Tapping a route chip or a departure row passes its GTFS route id
    /// (the host draws the route on the map).
    var onSelectRoute: ((String) -> Void)? = nil

    @State private var railArrivals: [IrishRailArrival] = []
    @State private var luasForecast: LuasStopForecast?
    @State private var isLoading = true
    /// When the displayed arrivals were last refreshed. Drives the "Updated
    /// Xs ago" header label. nil = no successful fetch yet.
    @State private var lastUpdated: Date? = nil
    /// Drives the auto-refresh ticker so the header label updates from
    /// "just now" → "30s ago" → ... while the sheet stays open.
    @State private var refreshTick: Int = 0
    @State private var isRefreshing: Bool = false
    /// The last live fetch failed. Whatever loaded before stays on screen
    /// (with its own "Updated …" time) under a "Can't reach live times" row.
    @State private var liveFeedFailed = false
    /// A live source (Luas stop / rail station) was found and answered at
    /// least once, so an empty list really means "nothing due".
    @State private var liveLoadedOnce = false

    // Scheduled times (downloadable SQLite). Every stop kind: for Luas /
    // DART / rail it is what's left when the live feeds are down.
    @State private var timetable: BusTimetableService.DownloadState?
    @State private var busDepartures: [BusDeparture] = []
    @State private var busRoutes: [TransitRoute] = []
    @State private var busLoaded = false
    @State private var busLoadedAt: Date?
    /// False once today is past the installed timetable's service window, so
    /// an empty board reads "out of date" rather than "no departures".
    @State private var timetableCoversToday = true
    @State private var isUpdatingTimetable = false
    @State private var downloadWatcher: Task<Void, Never>?

    private let railService = IrishRailService()
    private let luasService = LuasService()

    private var showsBus: Bool { stop.isServed(by: .bus) }
    private var showsLuas: Bool { stop.isServed(by: .luas) }
    private var showsDart: Bool { stop.isServed(by: .dart) }
    private var showsRail: Bool { stop.isServed(by: .rail) }
    private var showsLive: Bool { showsLuas || showsDart || showsRail }

    private var hasLiveData: Bool {
        !filteredRailArrivals.isEmpty
            || !(luasForecast?.inbound.isEmpty ?? true)
            || !(luasForecast?.outbound.isEmpty ?? true)
    }

    /// DART-only stops show DART trains, rail-only stops the rest; shared
    /// stations (Connolly) show everything.
    private var filteredRailArrivals: [IrishRailArrival] {
        guard !railArrivals.isEmpty else { return [] }
        switch (showsDart, showsRail) {
        case (true, false): return railArrivals.filter { $0.trainType.uppercased() == "DART" }
        case (false, true): return railArrivals.filter { $0.trainType.uppercased() != "DART" }
        default: return railArrivals
        }
    }

    private var railTitle: String {
        switch (showsDart, showsRail) {
        case (true, false): return "DART"
        case (false, true): return "Rail"
        default: return "Trains"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Drag indicator
                HStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 40, height: 5)
                    Spacer()
                }
                .padding(.top, 8)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(stop.name)
                        .font(.title3.bold())
                    if let code = stop.code {
                        Text("Stop \(code)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    Spacer()
                    FavoriteStopButton(stopId: stop.id)
                }

                // Freshness header — when the sheet's arrivals were last
                // pulled and a manual refresh button.
                HStack(spacing: 8) {
                    Image(systemName: isRefreshing ? "arrow.triangle.2.circlepath" : "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(freshnessLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .id(refreshTick)  // force re-eval so the label ticks even without state change
                    Spacer()
                    Button(action: { Task { await refreshArrivals() } }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                            .padding(7)
                            .background(.thinMaterial, in: Circle())
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isRefreshing)
                    .accessibilityLabel("Refresh times")
                }

                // Only show the live-feed spinner when no data has arrived yet
                if showsLive && isLoading && !liveLoadedOnce
                    && luasForecast == nil && railArrivals.isEmpty {
                    HStack { Spacer(); ProgressView("Loading arrivals..."); Spacer() }
                        .padding()
                }

                // Luas arrivals
                if let forecast = luasForecast {
                    if !forecast.message.isEmpty {
                        // Orange only for a real disruption; routine notices
                        // read as plain secondary text.
                        if TransitFeed.isDisruption(forecast.message) {
                            Label(forecast.message, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            Text(forecast.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !forecast.inbound.isEmpty {
                        arrivalSection(title: "Inbound", forecasts: forecast.inbound, color: .blue)
                    }
                    if !forecast.outbound.isEmpty {
                        arrivalSection(title: "Outbound", forecasts: forecast.outbound, color: .green)
                    }
                }

                // Irish Rail arrivals
                if !filteredRailArrivals.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(railTitle)
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)

                        ForEach(filteredRailArrivals) { arrival in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(arrival.destination)
                                            .font(.subheadline.bold())
                                        Text("(\(arrival.trainType))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text("from \(arrival.origin)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if !arrival.status.isEmpty {
                                        Text(arrival.status)
                                            .font(.caption2)
                                            .foregroundStyle(TransitFeed.isDisruption(arrival.status)
                                                             ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                                    }
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 2) {
                                    dueText(minutes: arrival.dueIn)
                                    Text(arrival.expectedArrival)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    sourceBadge(isRealTime: true)
                                }
                            }
                            .padding(10)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }

                if showsLive && liveFeedFailed {
                    liveFailureRow
                } else if showsLive && !isLoading && !hasLiveData {
                    Text(liveLoadedOnce ? "No departures in the next hour" : "No live times for this stop")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }

                timetableSection
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .task {
            await loadArrivals()
        }
        .task {
            await prepareTimetable()
        }
        .onDisappear {
            // Detaches from the download; the download itself keeps going.
            downloadWatcher?.cancel()
        }
        // Every 5 s: tick the freshness label and drop buses that have
        // left (no re-fetch of the live feeds).
        .task(id: lastUpdated) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                refreshTick &+= 1
                await reloadBusIfRunningLow()
            }
        }
    }

    /// Inline, non-alarming failure line with a retry. Last good times stay
    /// on screen above it.
    private var liveFailureRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(timetableIsReady ? "Can't reach live times. Scheduled times below." : "Can't reach live times")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Retry") { Task { await refreshArrivals() } }
                .font(.caption.bold())
                .frame(minWidth: 44, minHeight: 44)
                .disabled(isRefreshing)
        }
        .padding(.horizontal, 10)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    /// "Due" in bold primary, otherwise "N min". No alarm colours: a train
    /// being close is not a problem.
    private func dueText(minutes: Int?, fallback: String = "") -> some View {
        let text: String
        switch minutes {
        case .some(let m) where m <= 0: text = "Due"
        case .some(let m): text = "\(m) min"
        case .none: text = fallback
        }
        return Text(text)
            .font(.headline)
            .foregroundStyle(.primary)
    }

    // MARK: - Timetable section

    private var timetableIsReady: Bool {
        if case .ready = timetable { return true }
        return false
    }

    @ViewBuilder
    private var timetableSection: some View {
        switch timetable {
        case .none:
            EmptyView()
        case .notDownloaded:
            timetableCard {
                Button(action: startDownload) {
                    Label("Download timetable (13 MB)", systemImage: "arrow.down.circle")
                        .font(.subheadline.bold())
                }
                Text(showsLive
                     ? "Scheduled times for when live times can't be reached, available offline."
                     : "Scheduled bus times, available offline once downloaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .downloading(let fraction):
            timetableCard {
                ProgressView(value: fraction)
                Text("Downloading timetable… \(Int((fraction * 100).rounded()))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            timetableCard {
                HStack {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry", action: startDownload)
                        .font(.caption.bold())
                }
            }
        case .ready(let built):
            busTimetable(built: built)
        }
    }

    private func timetableCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6, content: content)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func busTimetable(built: String?) -> some View {
        // Routes serving this stop
        if !busRoutes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Routes at this stop")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)

                FlowLayout(spacing: 6) {
                    ForEach(busRoutes) { route in
                        Button(action: { onSelectRoute?(route.id) }) {
                            Text(Self.routeLabel(route.short))
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.blue.opacity(0.15))
                                .foregroundStyle(.blue)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            .padding(.bottom, 4)
        }

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(showsLive ? "Timetable" : "Next Departures")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                if let built, let label = Self.timetableUpdatedLabel(built) {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // `refreshTick` re-renders this every 5 s, so a bus that has
            // left drops off instead of staying "Due".
            let _ = refreshTick
            let now = Date()
            let upcoming = BusDeparture.upcoming(busDepartures, now: now)

            if busLoaded && upcoming.isEmpty {
                timetableCard {
                    if timetableCoversToday {
                        Label("No scheduled departures in the next 2 hours",
                              systemImage: showsBus ? "bus.fill" : "tram.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Label("Timetable is out of date", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if isUpdatingTimetable {
                                ProgressView()
                            } else {
                                Button("Update") { Task { await updateTimetable() } }
                                    .font(.caption.bold())
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                        }
                    }
                }
            }

            ForEach(upcoming.prefix(10)) { dep in
                Button(action: { onSelectRoute?(dep.routeId) }) {
                    HStack {
                        Text(Self.routeLabel(dep.routeShortName))
                            .font(.subheadline.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.blue.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                        Text(dep.headsign.isEmpty ? (dep.direction == 0 ? "Outbound" : "Inbound") : dep.headsign)
                            .font(.subheadline)

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            dueText(minutes: dep.minutesUntil(now))
                            Text(dep.scheduledTime)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            sourceBadge(isRealTime: false)
                        }

                        Image(systemName: "map")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                    .padding(10)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(TapFeedbackStyle())
            }
        }
    }

    /// Reads the timetable state; loads departures when it is on the device,
    /// re-attaches to a download already in flight.
    private func prepareTimetable() async {
        let state = await BusTimetableService.shared.currentState()
        timetable = state
        switch state {
        case .ready: await loadBus()
        case .downloading: startDownload()
        default: break
        }
    }

    private func startDownload() {
        downloadWatcher?.cancel()
        timetable = .downloading(fraction: 0)
        downloadWatcher = Task {
            let stream = await BusTimetableService.shared.ensureAvailable()
            for await state in stream {
                timetable = state
            }
            if case .ready = timetable { await loadBus() }
        }
    }

    private func loadBus() async {
        let service = BusTimetableService.shared
        async let departures = service.departures(stopId: stop.id, altIds: stop.altIds, from: Date())
        async let routes = service.routes(forStop: stop.id, altIds: stop.altIds)
        busDepartures = (try? await departures) ?? []
        busRoutes = (try? await routes) ?? []
        timetableCoversToday = await service.covers(Date())
        busLoaded = true
        busLoadedAt = Date()
        if lastUpdated == nil || !showsLive { lastUpdated = Date() }
    }

    /// Fetches a newer timetable (the installed one keeps serving until it is
    /// swapped in), then reloads the board.
    private func updateTimetable() async {
        isUpdatingTimetable = true
        _ = await BusTimetableService.shared.checkForUpdate()
        timetable = await BusTimetableService.shared.currentState()
        await loadBus()
        isUpdatingTimetable = false
    }

    /// TFI gives most Irish Rail routes the short name "rail"; everything
    /// else ("39A", "Red", "DART", "Commuter") reads fine as published.
    nonisolated static func routeLabel(_ short: String) -> String {
        short.lowercased() == "rail" ? "Rail" : short
    }

    /// Re-queries the timetable once fewer than 5 departures remain, at
    /// most once a minute (a quiet stop may simply have few buses).
    private func reloadBusIfRunningLow() async {
        guard busLoaded, case .ready = timetable else { return }
        let now = Date()
        guard BusDeparture.upcoming(busDepartures, now: now).count < 5,
              now.timeIntervalSince(busLoadedAt ?? .distantPast) >= 60 else { return }
        await loadBus()
    }

    /// `"2026-10-18"` → "Timetable updated 18 Oct". The build date is a
    /// calendar day, so it is formatted in UTC to stay on the same day in
    /// every time zone.
    nonisolated static func timetableUpdatedLabel(_ built: String) -> String? {
        guard let date = BusTimetableService.isoDay(built) else { return nil }
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        style.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return "Timetable updated \(date.formatted(style))"
    }

    /// "Live" (green) or "Schedule" (gray) pill next to each arrival time.
    @ViewBuilder
    private func sourceBadge(isRealTime: Bool) -> some View {
        Text(isRealTime ? "Live" : "Schedule")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isRealTime ? Color.green.opacity(0.18) : Color.secondary.opacity(0.15))
            .foregroundStyle(isRealTime ? Color.green : Color.secondary)
            .clipShape(Capsule())
    }

    /// Human-readable label for the lastUpdated timestamp.
    private var freshnessLabel: String {
        guard let lastUpdated else {
            return isLoading ? "Loading…" : "Not loaded"
        }
        let secs = Int(Date().timeIntervalSince(lastUpdated))
        _ = refreshTick  // dependency
        if secs < 5 { return "Updated just now" }
        if secs < 60 { return "Updated \(secs)s ago" }
        if secs < 3600 { return "Updated \(secs / 60)m ago" }
        return "Updated \(secs / 3600)h ago"
    }

    /// Re-fetches the live feeds and, when the timetable is on the device,
    /// the scheduled departures.
    private func refreshArrivals() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        await loadArrivals()
        if case .ready = timetable { await loadBus() }
        isRefreshing = false
    }

    @ViewBuilder
    private func arrivalSection(title: String, forecasts: [LuasForecast], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)

            ForEach(forecasts) { forecast in
                HStack {
                    Image(systemName: "tram.fill")
                        .foregroundStyle(color)
                        .frame(width: 20)
                    Text(forecast.destination)
                        .font(.subheadline)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        dueText(minutes: forecast.dueMinutes, fallback: forecast.dueIn)
                        sourceBadge(isRealTime: true)
                    }
                }
                .padding(10)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    /// Live feeds only (Luas, Irish Rail). Never waits on the timetable.
    /// On failure the last good data and its timestamp stay; only a fully
    /// successful pass moves `lastUpdated`.
    private func loadArrivals() async {
        guard showsLive else { isLoading = false; return }
        isLoading = true
        var failed = false
        var answered = false

        if showsLuas {
            // Match by station name against the Luas forecast API stop list.
            let lowerName = stop.name.lowercased()
            let matchedStop = LuasService.stops.first { luasStop in
                let luasName = luasStop.name.lowercased()
                return lowerName.contains(luasName) || luasName.contains(lowerName)
            }
            if let matchedStop {
                do {
                    luasForecast = try await luasService.forecast(stopCode: matchedStop.id)
                    answered = true
                } catch {
                    failed = true
                }
            }
        }

        if showsDart || showsRail {
            do {
                let allStations = try await railService.stations()
                if let station = IrishRailStation.nearest(to: stop.coordinate, in: allStations) {
                    railArrivals = try await railService.arrivals(stationCode: station.id, withinMinutes: 60)
                    answered = true
                }
            } catch {
                failed = true
            }
        }

        liveFeedFailed = failed
        if answered { liveLoadedOnce = true }
        isLoading = false
        if !failed && answered { lastUpdated = Date() }
    }
}

// MARK: - Flow Layout (wrapping horizontal layout for route pills)

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}

// MARK: - Favorite Stop Button

/// Star toggle for pinning a stop (persisted by `TransitLayerSettings`).
struct FavoriteStopButton: View {
    let stopId: String
    private let settings = TransitLayerSettings.shared

    var body: some View {
        let isFavorite = settings.isPinned(stopId)
        Button(action: { settings.togglePinned(stopId) }) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .foregroundStyle(isFavorite ? .yellow : .secondary)
                .font(.title3)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFavorite ? "Unpin stop" : "Pin stop")
    }
}

// MARK: - Tap Feedback Button Style

private struct TapFeedbackStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

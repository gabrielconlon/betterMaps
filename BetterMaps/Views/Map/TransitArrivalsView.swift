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

    // Bus timetable (downloadable SQLite)
    @State private var timetable: BusTimetableService.DownloadState?
    @State private var busDepartures: [BusDeparture] = []
    @State private var busRoutes: [TransitRoute] = []
    @State private var busLoaded = false
    @State private var downloadWatcher: Task<Void, Never>?

    private let railService = IrishRailService()
    private let luasService = LuasService()

    private var showsBus: Bool { stop.isServed(by: .bus) }
    private var showsLuas: Bool { stop.isServed(by: .luas) }
    private var showsDart: Bool { stop.isServed(by: .dart) }
    private var showsRail: Bool { stop.isServed(by: .rail) }

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
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.caption2)
                            .labelStyle(.iconOnly)
                            .padding(6)
                            .background(.thinMaterial)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isRefreshing)
                }

                // Only show the live-feed spinner when no data has arrived yet
                if (showsLuas || showsDart || showsRail) && isLoading
                    && luasForecast == nil && railArrivals.isEmpty {
                    HStack { Spacer(); ProgressView("Loading arrivals..."); Spacer() }
                        .padding()
                }

                // Luas arrivals
                if let forecast = luasForecast {
                    if !forecast.message.isEmpty {
                        let isNormal = forecast.message.localizedCaseInsensitiveContains("operating normally")
                            || forecast.message.localizedCaseInsensitiveContains("normal service")
                        if isNormal {
                            Label(forecast.message, systemImage: "checkmark.circle")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Label(forecast.message, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
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
                                            .foregroundStyle(.orange)
                                    }
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(arrival.dueIn == 0 ? "DUE" : "\(arrival.dueIn) min")
                                        .font(.headline)
                                        .foregroundStyle(arrival.dueIn <= 3 ? .red : .primary)
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

                if showsBus {
                    busSection
                }

                if !showsBus && !isLoading && filteredRailArrivals.isEmpty && luasForecast == nil {
                    Text("No real-time arrivals available for this stop.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .task {
            await loadArrivals()
        }
        .task {
            guard showsBus else { return }
            await prepareTimetable()
        }
        .onDisappear {
            // Detaches from the download; the download itself keeps going.
            downloadWatcher?.cancel()
        }
        // Auto-refresh the freshness label every 5s without re-fetching.
        .task(id: lastUpdated) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                refreshTick &+= 1
            }
        }
    }

    // MARK: - Bus timetable section

    @ViewBuilder
    private var busSection: some View {
        switch timetable {
        case .none:
            EmptyView()
        case .notDownloaded:
            timetableCard {
                Button(action: startDownload) {
                    Label("Download bus timetable (13 MB)", systemImage: "arrow.down.circle")
                        .font(.subheadline.bold())
                }
                Text("Scheduled bus times, available offline once downloaded.")
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
                            Text(route.short)
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
                Text("Next Departures")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                if let built {
                    Text("Timetable \(built)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if busLoaded && busDepartures.isEmpty {
                timetableCard {
                    Label("No scheduled departures in the next 2 hours", systemImage: "bus.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            let now = Date()
            ForEach(busDepartures.prefix(10)) { dep in
                Button(action: { onSelectRoute?(dep.routeId) }) {
                    HStack {
                        Text(dep.routeShortName)
                            .font(.subheadline.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.blue.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                        Text(dep.headsign.isEmpty ? (dep.direction == 0 ? "Outbound" : "Inbound") : dep.headsign)
                            .font(.subheadline)

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            let due = dep.minutesUntil(now)
                            Text(due == 0 ? "DUE" : "\(due) min")
                                .font(.headline)
                                .foregroundStyle(due <= 3 ? .red : .primary)
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
        busLoaded = true
        if lastUpdated == nil || !(showsLuas || showsDart || showsRail) { lastUpdated = Date() }
    }

    /// "Live" (green) or "Schedule" (gray) pill next to each arrival time.
    @ViewBuilder
    private func sourceBadge(isRealTime: Bool) -> some View {
        Text(isRealTime ? "Live" : "Schedule")
            .font(.system(size: 9, weight: .bold))
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
        if showsBus, case .ready = timetable { await loadBus() }
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
                        Text(forecast.dueIn)
                            .font(.headline)
                            .foregroundStyle(forecast.dueMinutes == 0 ? .red : .primary)
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
    private func loadArrivals() async {
        isLoading = true

        if showsLuas {
            // Match by station name against the Luas forecast API stop list.
            let lowerName = stop.name.lowercased()
            let matchedStop = LuasService.stops.first { luasStop in
                let luasName = luasStop.name.lowercased()
                return lowerName.contains(luasName) || luasName.contains(lowerName)
            }
            if let matchedStop {
                luasForecast = await luasService.fetchForecast(stopCode: matchedStop.id)
            }
        }

        if showsDart || showsRail {
            let allStations = await railService.fetchStations()
            let nearbyStation = allStations.first { station in
                WaypointGraph.meters(
                    CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude),
                    stop.coordinate
                ) < 800
            }
            if let station = nearbyStation {
                railArrivals = await railService.fetchArrivals(stationCode: station.id)
            }
        }

        isLoading = false
        if showsLuas || showsDart || showsRail { lastUpdated = Date() }
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
        }
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

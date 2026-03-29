import SwiftUI

/// First-time setup screen shown on initial install.
/// Downloads and processes the GTFS transit database so the app
/// doesn't freeze when users toggle transit layers.
struct GTFSSetupView: View {
    @Binding var isComplete: Bool
    @State private var progress: Double = 0
    @State private var statusText = ""
    @State private var detailText = ""
    @State private var quipText = ""
    @State private var isWorking = false
    @State private var isDone = false
    @State private var hasFailed = false
    @State private var errorMessage: String?
    @State private var elapsedSeconds = 0
    @State private var timerTask: Task<Void, Never>?
    @State private var quipTask: Task<Void, Never>?
    @AppStorage("gtfsSetupStep") private var completedStep: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Icon cluster
            ZStack {
                Image(systemName: "map.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.blue.opacity(0.15))
                VStack(spacing: 4) {
                    HStack(spacing: 12) {
                        Image(systemName: "tram.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.green)
                        Image(systemName: "bus.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.blue)
                    }
                    Image(systemName: "train.side.front.car")
                        .font(.system(size: 22))
                        .foregroundStyle(.orange)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Welcome to BetterMaps")
                    .font(.title.bold())
                Text("beta")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.blue)
                    .clipShape(Capsule())
            }
            .padding(.top, 16)

            if !isWorking && !isDone {
                VStack(spacing: 8) {
                    Text("Irish transit data needs to be downloaded\nfor offline stops, routes, and timetables.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    Text("This is a one-time setup and can take\n2-5 minutes depending on your connection.")
                        .multilineTextAlignment(.center)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
                .padding(.horizontal, 32)
            }

            Spacer()

            // Progress section
            if isWorking || isDone || hasFailed {
                VStack(spacing: 10) {
                    steppedProgressBar
                        .padding(.bottom, 4)

                    ProgressView(value: progress, total: 1.0)
                        .progressViewStyle(.linear)
                        .tint(hasFailed ? .red : (isDone ? .green : .blue))
                        .animation(.easeInOut(duration: 0.5), value: progress)

                    HStack(spacing: 8) {
                        if isWorking && !isDone && !hasFailed {
                            ProgressView()
                                .controlSize(.small)
                        }
                        if isDone {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        if hasFailed {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        Text(statusText)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(isDone ? .green : (hasFailed ? .orange : .primary))
                    }

                    if !detailText.isEmpty {
                        Text(detailText)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    // Rotating quips to keep the user entertained
                    if !quipText.isEmpty && isWorking && !isDone && !hasFailed {
                        Text(quipText)
                            .font(.caption.italic())
                            .foregroundStyle(.secondary.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .transition(.opacity)
                            .id(quipText)
                            .padding(.top, 4)
                    }

                    if isWorking && !isDone && !hasFailed && elapsedSeconds > 0 {
                        Text("Elapsed: \(formattedTime(elapsedSeconds))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 40)

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .padding(.top, 8)
                }
            }

            Spacer()

            // Action buttons
            if !isWorking && !isDone && !hasFailed {
                Button {
                    Task { await performSetup() }
                } label: {
                    Text("Download Transit Data")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 40)
            } else if hasFailed {
                Button {
                    hasFailed = false
                    errorMessage = nil
                    Task { await performSetup() }
                } label: {
                    Text("Retry")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .padding(.horizontal, 40)
            } else if isDone {
                Button {
                    isComplete = true
                } label: {
                    Text("Open Map")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 40)
            }

            // Skip option
            if !isWorking || hasFailed {
                Button("Skip for now") {
                    timerTask?.cancel()
                    quipTask?.cancel()
                    isComplete = true
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 12)
            }

            VStack(spacing: 2) {
                Text("~65 MB download  \u{00B7}  No API key needed")
                Text("Open data from Transport for Ireland (TFI)")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.top, 16)
            .padding(.bottom, 30)
        }
        .onAppear {
            if completedStep > 0 && !isWorking && !isDone {
                progress = Double(completedStep) * 0.25
            }
        }
    }

    // MARK: - Stepped Progress

    private var steppedProgressBar: some View {
        HStack(spacing: 12) {
            ForEach(1...4, id: \.self) { step in
                VStack(spacing: 4) {
                    Circle()
                        .fill(step <= completedStep ? .green : (step == completedStep + 1 && isWorking ? .blue : Color(.systemGray4)))
                        .frame(width: 28, height: 28)
                        .overlay {
                            if step <= completedStep {
                                Image(systemName: "checkmark")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white)
                            } else {
                                Text("\(step)")
                                    .font(.caption2.bold())
                                    .foregroundStyle(step == completedStep + 1 && isWorking ? .white : .secondary)
                            }
                        }
                    Text(stepLabel(step))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func stepLabel(_ step: Int) -> String {
        switch step {
        case 1: return "Download"
        case 2: return "Database"
        case 3: return "Classify"
        case 4: return "Shapes"
        default: return ""
        }
    }

    // MARK: - Quips

    private static let downloadQuips = [
        "Convincing the TFI server we're worthy...",
        "The server is thinking about it...",
        "Downloading every bus stop in Ireland. Yes, all of them.",
        "This file is 65 MB. That's a lot of bus stops.",
        "Somewhere in Dublin, a server is working very hard right now.",
        "Fun fact: Ireland has more bus stops than roundabouts. Barely.",
        "Waiting for bytes like waiting for the 46A...",
        "The TFI server runs on vibes and good intentions.",
        "65 MB never felt so heavy.",
        "If this were a bus, it'd be 'due' any minute now.",
        "Establishing a meaningful connection with transportforireland.ie...",
        "Still faster than Bus Eireann WiFi.",
        "Loading... like a Dublin Bus on a rainy Monday.",
        "The server is on Irish time. We respect that.",
        "Counting every stop between Donabate and Greystones...",
    ]

    private static let buildQuips = [
        "Teaching the database about the 7am Maynooth commuter...",
        "Sorting 1.3 million timetable entries. No big deal.",
        "Building a tiny train set inside your phone.",
        "Every trip. Every stop. Every 4:37am service nobody takes.",
        "Indexing all the ways to get from A to B (and C, and D...)",
        "Making SQLite earn its keep.",
        "Crunching numbers like a Luas crunches leaves in autumn.",
        "The database is doing its stretches before the big run.",
        "Organising chaos into timetables since 2026.",
        "Filing 35,000 trips under 'sure it'll be grand'.",
        "Cross-referencing every DART with every Dublin Bus. Send help.",
        "Your phone is now an honorary transport planner.",
        "Wiring up connections even Irish Rail hasn't thought of.",
        "Turning CSV soup into queryable gold.",
        "Almost there... just 700,000 more shape points to go.",
    ]

    private static let classifyQuips = [
        "Figuring out which Connolly is which...",
        "DART or bus? The eternal question, answered 14,000 times.",
        "Telling Luas stops apart from suspiciously similar bus stops.",
        "Mapping the unmappable.",
        "Final touches. Like garnish, but for databases.",
    ]

    private func startQuipRotation(quips: [String]) {
        quipTask?.cancel()
        // Show first quip immediately
        withAnimation(.easeInOut(duration: 0.3)) {
            quipText = quips.randomElement() ?? ""
        }
        quipTask = Task { @MainActor in
            var used = Set<String>()
            used.insert(quipText)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 5...8)))
                guard !Task.isCancelled else { break }
                // Pick an unused quip, or reset if we've shown them all
                var remaining = quips.filter { !used.contains($0) }
                if remaining.isEmpty {
                    used.removeAll()
                    remaining = quips
                }
                let next = remaining.randomElement() ?? ""
                used.insert(next)
                withAnimation(.easeInOut(duration: 0.3)) {
                    quipText = next
                }
            }
        }
    }

    // MARK: - Setup Logic

    private func performSetup() async {
        isWorking = true
        isDone = false
        hasFailed = false
        errorMessage = nil
        elapsedSeconds = 0

        // Detect what's already done from cached artifacts
        var startStep = 0
        if GTFSStopLoader.hasCachedZip {
            startStep = max(startStep, 1)
        }
        if GTFSDatabase.isFresh {
            startStep = max(startStep, 2)
        }

        // Set initial progress based on completed work
        if startStep > 0 {
            completedStep = startStep
            progress = Double(startStep) * 0.25
        }

        // Start elapsed time counter
        timerTask?.cancel()
        timerTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                elapsedSeconds += 1
            }
        }

        // Step 1: Download GTFS ZIP and extract stops (~65 MB, slowest part)
        var stops: [TransitStop] = []
        if startStep < 1 {
            update(status: "Downloading transit data...",
                   detail: "~65 MB from transportforireland.ie",
                   progress: 0.05)
            startQuipRotation(quips: Self.downloadQuips)

            stops = await GTFSStopLoader().loadStops()
            if stops.isEmpty {
                quipTask?.cancel()
                fail("Could not download transit data.\nCheck your internet connection and try again.")
                return
            }
            completedStep = 1
            update(status: "Downloaded \(stops.count.formatted()) stops",
                   detail: "ZIP cached locally",
                   progress: 0.35)
        } else {
            stops = await GTFSStopLoader().loadStops()
            update(status: "Using cached download",
                   detail: "\(stops.count.formatted()) stops",
                   progress: 0.35)
        }

        // Step 2: Build SQLite database from cached ZIP (no second download!)
        if startStep < 2 {
            update(status: "Building schedule database...",
                   detail: "Parsing ~1,400 routes and millions of timetable entries",
                   progress: 0.40)
            startQuipRotation(quips: Self.buildQuips)

            await GTFSScheduleService.shared.loadIfNeeded()

            let tripCount = await GTFSScheduleService.shared.tripCount
            if tripCount == 0 {
                quipTask?.cancel()
                fail("Schedule database could not be built.\nThe transit data may have changed format.\nTap Retry or Skip to use the app without transit.")
                return
            }
            completedStep = 2
            update(status: "Loaded \(tripCount.formatted()) trips",
                   detail: "Schedule database ready",
                   progress: 0.75)
        } else {
            await GTFSScheduleService.shared.loadIfNeeded()
            let tripCount = await GTFSScheduleService.shared.tripCount
            update(status: "Database ready",
                   detail: "\(tripCount.formatted()) trips",
                   progress: 0.75)
        }

        // Step 3: Pre-compute stop classifications
        if startStep < 3 {
            update(status: "Classifying stops by transit type...",
                   detail: "Identifying Luas, DART, and rail stops from route data",
                   progress: 0.85)
            startQuipRotation(quips: Self.classifyQuips)

            let classification = await GTFSScheduleService.shared.classifyTramAndRailStops()
            completedStep = 3

            update(status: "Loading route shapes...",
                   detail: "\(classification.count) rail/tram stops identified",
                   progress: 0.92)
        } else {
            let classification = await GTFSScheduleService.shared.classifyTramAndRailStops()
            update(status: "Stops classified",
                   detail: "\(classification.count) rail/tram stops",
                   progress: 0.92)
        }

        // Step 4: Load route shapes (always runs, it's fast)
        let dartShapes = await GTFSScheduleService.shared.shapeCoordinatesForDART()
        let railShapes = await GTFSScheduleService.shared.shapeCoordinatesForNonDartRail()
        completedStep = 4

        // Build transit graph for instant route planning
        update(status: "Computing travel times...",
               detail: "Building route planner for instant searches",
               progress: 0.93)

        let activeServices = await GTFSScheduleService.shared.activeServiceIds(for: Date())
        let graphBuilder = TransitGraphBuilder()
        let transitGraph = await graphBuilder.build(
            db: GTFSScheduleService.shared.database,
            activeServices: activeServices,
            allStops: stops
        )
        await TransitRoutePlanner.shared.headwayRouter.setGraph(transitGraph)

        // Also build RAPTOR in background (for exact time refinement later)
        update(status: "Finalizing...",
               detail: "Building exact timetable index",
               progress: 0.97)

        let raptorEngine = await TransitRoutePlanner.shared.getRaptorEngine()
        await raptorEngine.buildIfNeeded(
            db: GTFSScheduleService.shared.database,
            activeServices: activeServices,
            allStops: stops
        )

        // Done
        let tripCount = await GTFSScheduleService.shared.tripCount
        timerTask?.cancel()
        quipTask?.cancel()
        withAnimation(.easeInOut(duration: 0.3)) { quipText = "" }
        update(status: "All set!",
               detail: "\(stops.count.formatted()) stops \u{00B7} \(tripCount.formatted()) trips \u{00B7} \(dartShapes.count) DART + \(railShapes.count) Rail shapes",
               progress: 1.0)
        isDone = true
        isWorking = false

        await APILogger.shared.log(
            service: "Setup", endpoint: "First-time install",
            status: .success, durationMs: elapsedSeconds * 1000,
            detail: "\(stops.count) stops, \(tripCount) trips, \(dartShapes.count + railShapes.count) shapes in \(elapsedSeconds)s"
        )
    }

    private func fail(_ message: String) {
        timerTask?.cancel()
        quipTask?.cancel()
        withAnimation(.easeInOut(duration: 0.3)) { quipText = "" }
        errorMessage = message
        hasFailed = true
        isWorking = false
        statusText = "Setup failed"
    }

    private func update(status: String, detail: String, progress: Double) {
        statusText = status
        detailText = detail
        withAnimation(.easeInOut(duration: 0.5)) {
            self.progress = progress
        }
    }

    private func formattedTime(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}

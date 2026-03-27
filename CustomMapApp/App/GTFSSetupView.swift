import SwiftUI

/// First-time setup screen shown on initial install.
/// Downloads and processes the GTFS transit database so the app
/// doesn't freeze when users toggle transit layers.
struct GTFSSetupView: View {
    @Binding var isComplete: Bool
    @State private var progress: Double = 0
    @State private var statusText = ""
    @State private var detailText = ""
    @State private var isWorking = false
    @State private var isDone = false
    @State private var hasFailed = false
    @State private var errorMessage: String?
    @State private var elapsedSeconds = 0
    @State private var timerTask: Task<Void, Never>?

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

            Text("Welcome to BetterMaps")
                .font(.title.bold())
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
    }

    // MARK: - Setup Logic

    private func performSetup() async {
        isWorking = true
        isDone = false
        hasFailed = false
        errorMessage = nil
        elapsedSeconds = 0

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
        update(status: "Downloading transit data...",
               detail: "~65 MB from transportforireland.ie — this is the slowest step",
               progress: 0.05)

        let stops = await GTFSStopLoader().loadStops()
        if stops.isEmpty {
            fail("Could not download transit data.\nCheck your internet connection and try again.")
            return
        }
        update(status: "Downloaded \(stops.count.formatted()) stops",
               detail: "ZIP cached locally — building schedule database next",
               progress: 0.35)

        // Step 2: Build SQLite database from cached ZIP (no second download!)
        update(status: "Building schedule database...",
               detail: "Parsing ~1,400 routes and timetables from cached data",
               progress: 0.40)

        await GTFSScheduleService.shared.loadIfNeeded()

        let tripCount = await GTFSScheduleService.shared.tripCount
        if tripCount == 0 {
            fail("Schedule database could not be built.\nThe transit data may have changed format.\nTap Retry or Skip to use the app without transit.")
            return
        }
        update(status: "Loaded \(tripCount.formatted()) trips",
               detail: "Schedule database ready",
               progress: 0.75)

        // Step 3: Pre-compute stop classifications
        update(status: "Classifying stops by transit type...",
               detail: "Identifying Luas, DART, and bus stops from route data",
               progress: 0.85)

        let classification = await GTFSScheduleService.shared.classifyTramAndRailStops()

        update(status: "Loading route shapes...",
               detail: "\(classification.count) rail/tram stops identified",
               progress: 0.92)

        let dartShapes = await GTFSScheduleService.shared.shapeCoordinatesForDART()
        let railShapes = await GTFSScheduleService.shared.shapeCoordinatesForNonDartRail()

        // Done
        timerTask?.cancel()
        update(status: "All set!",
               detail: "\(stops.count.formatted()) stops \u{00B7} \(tripCount.formatted()) trips \u{00B7} \(dartShapes.count) DART + \(railShapes.count) Rail shapes",
               progress: 1.0)
        isDone = true
        isWorking = false

        await APILogger.shared.log(
            service: "Setup", endpoint: "First-time install",
            status: .success, durationMs: elapsedSeconds * 1000,
            detail: "\(stops.count) stops, \(tripCount) trips, \(dartShapes.count + railShapes.count) shapes, \(classification.count) rail/tram classified in \(elapsedSeconds)s"
        )
    }

    private func fail(_ message: String) {
        timerTask?.cancel()
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

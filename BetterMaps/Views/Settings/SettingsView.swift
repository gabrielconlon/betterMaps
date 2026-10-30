import SwiftUI
import SwiftData

/// App settings: map style, iCloud sync status, offline transit data,
/// directions preferences, about, and an Advanced section (collapsed) for
/// the optional Yelp key, which lives in the Keychain.
struct SettingsView: View {
    /// "Show the welcome again": the map presents the walkthrough once this
    /// sheet has closed. Nil hides the row.
    var onShowWelcome: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage(MapStyleOption.storageKey) private var mapStyle: MapStyleOption = .standard
    @Query(sort: \DirectionsPreferences.updatedAt, order: .reverse) private var directionsRows: [DirectionsPreferences]

    @State private var timetable = BusTimetableModel()
    private let sync = CloudSyncMonitor.shared
    @State private var editingKey = ""
    /// The key as last saved, to enable Save only on a change.
    @State private var savedKey = ""
    @State private var keySaved = false
    @State private var showsReviewsKey = false
    @State private var confirmRemove = false
    @State private var bundleBuilt: Date?
    /// The last "Update" outcome, shown under the button for a few seconds.
    @State private var shownUpdateResult: String?

    var body: some View {
        NavigationStack {
            Form {
                mapSection
                syncSection
                transitSection
                directionsSection
                aboutSection
                advancedSection
            }
            .onAppear(perform: ensureDirectionsRow)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                savedKey = YelpService.apiKey
                editingKey = savedKey
                bundleBuilt = TransitBundle.builtDate(in: .main)
                await sync.refreshAccountStatus()
                await timetable.refresh()
            }
            .confirmationDialog("Remove the timetable?", isPresented: $confirmRemove,
                                titleVisibility: .visible) {
                Button("Remove", role: .destructive) { timetable.remove() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Scheduled departure times won't show until you download it again.")
            }
        }
    }

    // MARK: - Sections

    private var mapSection: some View {
        Section("Map") {
            Picker("Map style", selection: $mapStyle) {
                ForEach(MapStyleOption.allCases) { option in
                    Label(option.rawValue, systemImage: option.icon).tag(option)
                }
            }
        }
    }

    private var syncSection: some View {
        let status = sync.status
        return Section {
            LabeledContent("Status") {
                Label(status.title, systemImage: status.isProblem ? "exclamationmark.icloud" : "checkmark.icloud")
                    .foregroundStyle(status.isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            if let detail = status.detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("iCloud sync")
        } footer: {
            Text("Places, layers, trails and favourite routes sync to your iPhone, iPad and Mac when they're signed in to the same Apple Account.")
        }
    }

    /// Collapsed by default: most people never need a Yelp key.
    private var advancedSection: some View {
        Section("Advanced") {
            DisclosureGroup("Reviews and opening hours", isExpanded: $showsReviewsKey) {
                Text("Optional. Paste a Yelp Fusion key to show ratings and hours.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                SecureField("Yelp Fusion key", text: $editingKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: editingKey) { _, _ in keySaved = false }
                HStack {
                    Button("Save", action: saveKey)
                        .disabled(trimmedKey == savedKey)
                    Spacer()
                    if keySaved {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }
                }
                .frame(minHeight: 44)
            }
        }
    }

    private var transitSection: some View {
        Section {
            LabeledContent("Stops and lines") {
                Text(bundleBuilt.map { "Updated \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Included")
            }
            LabeledContent("Timetable") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(timetable.statusText).monospacedDigit()
                    if case .ready = timetable.state, let size = timetable.sizeText {
                        Text(size).font(.caption)
                    }
                }
            }
            timetableActions
        } header: {
            Text("Transit data")
        } footer: {
            Text("Stops and lines come with the app. The timetable is an optional download for scheduled bus, Luas, DART and rail times without a connection, or when live times are down.")
        }
    }

    @ViewBuilder
    private var timetableActions: some View {
        switch timetable.state {
        case .notDownloaded, .failed:
            Button("Download timetable") { timetable.download() }
        case .downloading(let fraction):
            ProgressView(value: fraction)
        case .ready:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Button(timetable.isCheckingForUpdate ? "Checking for a newer timetable…" : "Update timetable") {
                        Task { await timetable.checkForUpdateNow() }
                    }
                    .disabled(timetable.isCheckingForUpdate)
                    if timetable.isCheckingForUpdate {
                        Spacer()
                        ProgressView()
                    }
                }
                if let shownUpdateResult {
                    Text(shownUpdateResult)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .frame(minHeight: 44)
            // Show the last check's outcome for a few seconds, then clear it.
            .task(id: timetable.updateResultText) {
                shownUpdateResult = timetable.updateResultText
                guard shownUpdateResult != nil else { return }
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                withAnimation { shownUpdateResult = nil }
            }
            Button("Remove timetable", role: .destructive) { confirmRemove = true }
        case nil:
            EmptyView()
        }
    }

    /// The trip controls from the directions sheet plus the rarely changed
    /// ones, bound to the one preferences row; the sheet picks the change up
    /// on save.
    @ViewBuilder
    private var directionsSection: some View {
        if let row = directionsRows.first {
            Section {
                DirectionsSettingsControls(prefs: row.snapshot) { snapshot in
                    row.apply(snapshot)
                    try? modelContext.save()
                }
            } header: {
                Text("Directions")
            } footer: {
                DirectionsAttributionFooter()
            }
        }
    }

    /// Inserts the default preferences row on first open so the section
    /// has something to bind to.
    private func ensureDirectionsRow() {
        guard directionsRows.isEmpty else { return }
        _ = try? DirectionsPreferences.fetchOrCreate(in: modelContext)
        try? modelContext.save()
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: Self.versionString)
            if let onShowWelcome {
                Button {
                    onShowWelcome()
                    dismiss()
                } label: {
                    Label("Show the welcome again", systemImage: "hand.wave")
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("settings.showWelcome")
            }
        }
    }

    // MARK: - Helpers

    private var trimmedKey: String { editingKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func saveKey() {
        let key = trimmedKey
        editingKey = key
        YelpService.apiKey = key
        savedKey = key
        withAnimation { keySaved = true }
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }
}

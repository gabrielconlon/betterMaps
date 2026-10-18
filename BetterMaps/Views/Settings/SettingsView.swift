import SwiftUI

/// App settings: map style, offline transit data, about, and an Advanced
/// section (collapsed) for the optional Yelp key, which lives in the Keychain.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(MapStyleOption.storageKey) private var mapStyle: MapStyleOption = .standard

    @State private var timetable = BusTimetableModel()
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
                transitSection
                aboutSection
                advancedSection
            }
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
                await timetable.refresh()
            }
            .confirmationDialog("Remove the bus timetable?", isPresented: $confirmRemove,
                                titleVisibility: .visible) {
                Button("Remove", role: .destructive) { timetable.remove() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Bus departure times won't show until you download it again.")
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
            LabeledContent("Bus timetable") {
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
            Text("Stops and lines come with the app. The bus timetable is an optional download for departure times without a connection.")
        }
    }

    @ViewBuilder
    private var timetableActions: some View {
        switch timetable.state {
        case .notDownloaded, .failed:
            Button("Download bus timetable") { timetable.download() }
        case .downloading(let fraction):
            ProgressView(value: fraction)
        case .ready:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Button(timetable.isCheckingForUpdate ? "Checking for a newer timetable…" : "Update bus timetable") {
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
            Button("Remove bus timetable", role: .destructive) { confirmRemove = true }
        case nil:
            EmptyView()
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: Self.versionString)
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

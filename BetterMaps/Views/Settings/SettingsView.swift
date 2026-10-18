import SwiftUI

/// App settings: map style, optional Yelp key, offline transit data, about.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(MapStyleOption.storageKey) private var mapStyle: MapStyleOption = .standard
    @AppStorage("yelpAPIKey") private var yelpAPIKey = ""

    @State private var timetable = BusTimetableModel()
    @State private var editingKey = ""
    @State private var keySaved = false
    @State private var confirmRemove = false
    @State private var bundleBuilt: Date?

    var body: some View {
        NavigationStack {
            Form {
                mapSection
                placeDetailsSection
                transitSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                editingKey = yelpAPIKey
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

    private var placeDetailsSection: some View {
        Section {
            SecureField("Yelp API key", text: $editingKey)
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onChange(of: editingKey) { _, _ in keySaved = false }
            HStack {
                Button("Save", action: saveKey)
                    .disabled(trimmedKey == yelpAPIKey)
                Spacer()
                if keySaved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }
            .frame(minHeight: 44)
        } header: {
            Text("Place details")
        } footer: {
            Text("Adds ratings and hours to places you look up. Optional.")
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
            Button(timetable.isCheckingForUpdate ? "Checking for a newer timetable…" : "Update bus timetable") {
                timetable.checkForUpdate()
            }
            .disabled(timetable.isCheckingForUpdate)
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
        yelpAPIKey = key
        YelpService.apiKey = key
        withAnimation { keySaved = true }
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }
}

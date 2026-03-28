import SwiftUI
import SwiftData

struct UserPreferencesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [UserProfile]

    var profile: UserProfile? { profiles.first }

    var body: some View {
        Form {
            if let profile {
                transportModesSection(profile)
                transitOptionsSection(profile)
            } else {
                Text("Loading preferences...")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("My Preferences")
    }

    // MARK: - Transport Modes

    @ViewBuilder
    private func transportModesSection(_ profile: UserProfile) -> some View {
        Section("Transport Modes") {
            Text("Choose which modes appear in route results. Preferred modes are shown first.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(TransportMode.allCases) { mode in
                HStack {
                    Image(systemName: mode.systemImage)
                        .foregroundStyle(mode.color)
                        .frame(width: 24)
                    Text(mode.displayName)
                        .font(.body)

                    Spacer()

                    // Three-state: Preferred / Normal / Disabled
                    Picker("", selection: modeStateBinding(profile, mode: mode)) {
                        Image(systemName: "star.fill").tag(ModeState.preferred)
                        Image(systemName: "checkmark").tag(ModeState.normal)
                        Image(systemName: "xmark").tag(ModeState.disabled)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }
            }
        }

        Section {
            Text("★ = Preferred (shown first)  ✓ = Normal  ✕ = Disabled (hidden)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Transit Options

    @ViewBuilder
    private func transitOptionsSection(_ profile: UserProfile) -> some View {
        Section("Transit Options") {
            HStack {
                Text("Max transfers")
                Spacer()
                Picker("", selection: Binding(
                    get: { profile.maxTransfers },
                    set: { profile.maxTransfers = $0; profile.updatedAt = Date() }
                )) {
                    Text("Direct only").tag(0)
                    Text("1 transfer").tag(1)
                    Text("2 transfers").tag(2)
                    Text("3 transfers").tag(3)
                }
                .pickerStyle(.menu)
            }

            // Transit preference is now driven by map layer toggles and favorites.
            // Toggle Luas/DART layers on → tram/rail routes are prioritized.
            // Favorite a route → it always ranks higher.
            Text("Tip: Toggle transit layers on the map to prioritize modes. Favorite stops to boost specific routes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Mode State Helpers

    enum ModeState: Int {
        case preferred = 0
        case normal = 1
        case disabled = 2
    }

    private func modeStateBinding(_ profile: UserProfile, mode: TransportMode) -> Binding<ModeState> {
        Binding(
            get: {
                if profile.disabledModes.contains(mode.rawValue) { return .disabled }
                if profile.preferredModes.contains(mode.rawValue) { return .preferred }
                return .normal
            },
            set: { newState in
                // Remove from all lists first
                profile.disabledModes.removeAll { $0 == mode.rawValue }
                profile.preferredModes.removeAll { $0 == mode.rawValue }
                profile.lastResortModes.removeAll { $0 == mode.rawValue }

                switch newState {
                case .preferred:
                    profile.preferredModes.append(mode.rawValue)
                case .normal:
                    break // just normal, not in any list
                case .disabled:
                    profile.disabledModes.append(mode.rawValue)
                }
                profile.updatedAt = Date()
            }
        )
    }
}

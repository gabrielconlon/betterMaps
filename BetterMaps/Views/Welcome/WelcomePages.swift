import SwiftUI

// MARK: - Shared header

/// Every page's top: one symbol, one headline, two lines of copy.
struct WelcomePageHeader: View {
    let systemImage: String
    let headline: String
    let copy: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.tint)
                .frame(height: 56)
                .accessibilityHidden(true)
            Text(headline)
                .font(.title.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(copy)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 24)
    }
}

/// The rounded card every page's control sits in, matching Settings' inset
/// grouped rows.
private struct WelcomeCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - 1. Welcome

struct WelcomeIntroPage: View {
    var body: some View {
        WelcomePageHeader(
            systemImage: "map.fill",
            headline: "Welcome to BetterMaps",
            copy: "A map of your places and Ireland's transit, with directions that respect how you travel.\nTwo quick choices and you're on your way."
        )
    }
}

// MARK: - 2. Transit layers

/// The four network switches, bound to the same `TransitLayerSettings` the
/// Layers card uses, so what is chosen here is already on the map.
struct WelcomeTransitPage: View {
    @Bindable var settings: TransitLayerSettings

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            WelcomePageHeader(
                systemImage: "tram.fill",
                headline: "Transit on the map",
                copy: "Turn on the networks you ride. BetterMaps draws their stops and lines on the map.\nChange this any time from the Layers button."
            )
            WelcomeCard {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(TransitLayerKind.allCases) { kind in
                        tile(kind)
                    }
                }
            }
        }
    }

    private func tile(_ kind: TransitLayerKind) -> some View {
        let isOn = settings.isEnabled(kind)
        let color = TransitColors.pin(kind)
        return Button {
            settings.toggle(kind)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: kind.systemImage)
                    .font(.title3.weight(.semibold))
                    .frame(width: 28)
                Text(kind.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(isOn ? color.opacity(0.25) : Color(.systemGray5),
                        in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(isOn ? color : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isOn)
        .accessibilityLabel(kind.displayName)
        .accessibilityValue(isOn ? "Shown" : "Hidden")
        .accessibilityHint(isOn ? "Hides \(kind.displayName)" : "Shows \(kind.displayName)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("welcome.transit.\(kind.rawValue)")
    }
}

// MARK: - 3. Getting around

/// The directions preferences, the same controls Settings shows, bound to the
/// one SwiftData row through `onChange`.
struct WelcomeGettingAroundPage: View {
    let prefs: DirectionsPreferencesSnapshot
    let onChange: (DirectionsPreferencesSnapshot) -> Void

    var body: some View {
        VStack(spacing: 0) {
            WelcomePageHeader(
                systemImage: "figure.walk",
                headline: "Getting around",
                copy: "How far you'll walk, which networks to ride, and whether to offer cycling.\nSet once; change any trip from the Options row."
            )
            WelcomeCard {
                DirectionsSettingsControls(prefs: prefs, onChange: onChange)
            }
        }
    }
}

// MARK: - 4. Done

struct WelcomeDonePage: View {
    let lines: [WelcomeSummary.Line]

    var body: some View {
        VStack(spacing: 0) {
            WelcomePageHeader(
                systemImage: "checkmark.circle.fill",
                headline: "You're set",
                copy: "Here's what you chose. Change any of it later in Settings.\nLong-press the map to save your first place."
            )
            WelcomeCard {
                ForEach(lines) { line in
                    LabeledContent(line.title) {
                        Text(line.value)
                            .multilineTextAlignment(.trailing)
                            .fontWeight(.medium)
                    }
                    .frame(minHeight: 32)
                    .accessibilityElement(children: .combine)
                    if line.id != lines.last?.id {
                        Divider()
                    }
                }
            }
            .accessibilityIdentifier("welcome.summary")
        }
    }
}

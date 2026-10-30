import SwiftUI
import SwiftData
import CoreLocation

/// The directions sheet: from / to, when, the travel options (folded), then
/// the journeys found. Picking one swaps the list for its timeline and draws
/// it on the map. Everything lives in this one sheet: the endpoint picker
/// replaces the content rather than stacking another sheet.
struct DirectionsSheet: View {
    let model: DirectionsViewModel
    /// An option was picked: the host drops the sheet so the map shows it.
    let onSelectItinerary: () -> Void
    /// Fallback when planning fails or finds nothing.
    let onOpenInAppleMaps: (_ name: String, _ coordinate: CLLocationCoordinate2D) -> Void
    /// The endpoint picker opened: the host raises the sheet for the keyboard.
    var onEditEndpoints: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var editing: DirectionsEndpointPicker.Which?
    @State private var showsOptions = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let editing {
                    DirectionsEndpointPicker(
                        which: editing,
                        userLocation: model.userLocation,
                        onPick: { endpoint in
                            if editing == .origin { model.setOrigin(endpoint) } else { model.setDestination(endpoint) }
                            self.editing = nil
                        },
                        onCancel: { self.editing = nil }
                    )
                } else {
                    header
                    if let selected = model.selectedItinerary {
                        selectedView(selected)
                    } else {
                        planningView
                    }
                    DirectionsAttributionFooter()
                }
            }
            .padding(.horizontal)
            // Clears the system drag indicator, the sheet's only grabber.
            .padding(.top, 20)
            .padding(.bottom)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(spacing: 6) {
                endpointButton(.origin, model.origin, placeholder: "Choose a starting point",
                               icon: "circle", color: .blue)
                endpointButton(.destination, model.destination, placeholder: "Choose a destination",
                               icon: "mappin.circle.fill", color: .red)
            }
            Button(action: model.swapEndpoints) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityLabel("Swap start and destination")
            .disabled(model.origin == nil && model.destination == nil)

            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close directions")
            .accessibilityIdentifier("directions.close")
        }
    }

    private func endpointButton(_ which: DirectionsEndpointPicker.Which, _ endpoint: DirectionsEndpoint?,
                                placeholder: String, icon: String, color: Color) -> some View {
        Button {
            editing = which
            onEditEndpoints()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.callout)
                    .foregroundStyle(color)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(endpoint?.name ?? placeholder)
                    .font(.subheadline.weight(endpoint == nil ? .regular : .semibold))
                    .foregroundStyle(endpoint == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .frame(maxWidth: .infinity)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(which.title): \(endpoint?.name ?? "not set")")
        .accessibilityHint("Changes the \(which == .origin ? "starting point" : "destination")")
        .accessibilityIdentifier(which == .origin ? "directions.origin" : "directions.destination")
    }

    // MARK: - Planning

    @ViewBuilder
    private var planningView: some View {
        DirectionsTimeControls(departNow: model.departNow, time: model.time, arriveBy: model.arriveBy,
                               onSetDepartNow: model.setDepartNow(_:),
                               onSetTime: model.setTime(_:),
                               onSetArriveBy: model.setArriveBy(_:))

        DisclosureGroup(isExpanded: $showsOptions) {
            VStack(alignment: .leading, spacing: 4) {
                DirectionsControls(prefs: model.prefs, onChange: model.apply(_:))
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Text("Options")
                    .font(.subheadline.weight(.semibold))
                Text(optionsSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minHeight: 32)
        }
        .tint(.primary)
        .accessibilityIdentifier("directions.options")

        results
    }

    /// "Walk 10 min · Bus, Luas, DART, Rail · 2 changes"
    private var optionsSummary: String {
        let modes = DirectionsControlsOrder.modes.filter { model.prefs.enabledModes.contains($0) }
        let modeText = modes.isEmpty ? "no transit" : modes.map(\.displayName).joined(separator: ", ")
        let changes = model.prefs.maxTransfers == 1 ? "1 change" : "\(model.prefs.maxTransfers) changes"
        return "Walk \(model.prefs.walkToleranceMinutes) min · \(modeText) · \(changes)"
    }

    @ViewBuilder
    private var results: some View {
        switch model.phase {
        case .idle:
            if model.origin == nil {
                StatusView(status: .empty(title: "Where are you starting from?",
                                          hint: "Location is unknown, so pick a starting point above.",
                                          systemImage: "location.slash",
                                          action: (label: "Choose a start", id: "origin"))) { _ in
                    editing = .origin
                    onEditEndpoints()
                }
            } else {
                StatusView(status: .empty(title: "Choose a destination", hint: nil,
                                          systemImage: "mappin.slash", action: nil))
            }

        case .loading:
            if model.itineraries.isEmpty {
                SkeletonRows(count: 2)
                    .accessibilityLabel("Finding journeys")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    StatusView(status: .loading("Updating…"))
                    itineraryList.opacity(0.55)
                }
            }

        case .results:
            itineraryList

        case .empty(let suggestRelaxWalk, let suggestTransfers):
            VStack(spacing: 8) {
                StatusView(status: .empty(title: "No journeys found",
                                          hint: emptyHint(suggestRelaxWalk: suggestRelaxWalk,
                                                          suggestTransfers: suggestTransfers),
                                          systemImage: "tram", action: nil))
                HStack(spacing: 8) {
                    if suggestRelaxWalk {
                        Button("Walk up to 20 min") { model.relaxWalkingLimit() }
                            .buttonStyle(.bordered)
                    }
                    if suggestTransfers {
                        Button("Allow changes") { model.allowTransfers() }
                            .buttonStyle(.bordered)
                    }
                }
                .controlSize(.small)
                .frame(minHeight: suggestRelaxWalk || suggestTransfers ? 44 : 0)
                appleMapsButton
            }
            .accessibilityIdentifier("directions.empty")

        case .unreachable(let message):
            VStack(spacing: 8) {
                StatusView(status: .failed(message: message, retryId: "retry")) { _ in
                    model.scheduleQuery(immediate: true)
                }
                appleMapsButton
            }
            .accessibilityIdentifier("directions.unreachable")
        }
    }

    private func emptyHint(suggestRelaxWalk: Bool, suggestTransfers: Bool) -> String {
        switch (suggestRelaxWalk, suggestTransfers) {
        case (true, true): return "Try walking further or allowing a change."
        case (true, false): return "Try walking a little further."
        case (false, true): return "Try allowing a change."
        case (false, false): return "Try another time or a nearby destination."
        }
    }

    private var itineraryList: some View {
        VStack(spacing: 8) {
            ForEach(Array(model.itineraries.enumerated()), id: \.element.id) { index, itinerary in
                ItineraryCard(itinerary: itinerary, index: index,
                              isSelected: itinerary.id == model.selectedId) {
                    model.select(itinerary)
                    onSelectItinerary()
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("directions.results")
    }

    @ViewBuilder
    private var appleMapsButton: some View {
        if let destination = model.destination {
            Button {
                onOpenInAppleMaps(destination.name, destination.coordinate)
            } label: {
                Label("Open in Apple Maps", systemImage: "arrow.triangle.turn.up.right.diamond")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Selected option

    @ViewBuilder
    private func selectedView(_ itinerary: Itinerary) -> some View {
        Button {
            model.clearSelection()
        } label: {
            Label("All journeys", systemImage: "chevron.left")
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .accessibilityIdentifier("directions.back")

        HStack(alignment: .firstTextBaseline) {
            Text(DirectionsFormat.minutes(itinerary.durationSeconds))
                .font(.title2.weight(.bold))
                .monospacedDigit()
            Spacer(minLength: 8)
            Text(DirectionsFormat.timeRange(itinerary.start, itinerary.end))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        Text(DirectionsFormat.summary(walkSeconds: itinerary.walkSeconds, bikeSeconds: itinerary.bikeSeconds,
                                      transfers: itinerary.transfers))
            .font(.subheadline)
            .foregroundStyle(.secondary)
        ModeChipStrip(legs: itinerary.legs)

        Divider()

        ItineraryTimeline(itinerary: itinerary, onShowOnMap: { dismiss() })
            .accessibilityIdentifier("directions.timeline")
    }
}

/// The order networks are listed in, shared by the controls and summaries.
enum DirectionsControlsOrder {
    static let modes: [TransitMode] = [.bus, .luas, .dart, .rail]
}

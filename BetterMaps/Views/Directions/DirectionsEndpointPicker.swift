import SwiftUI
import SwiftData
import MapKit

/// Picks one end of a journey inside the directions sheet (no second sheet):
/// a search field over saved places, stops and nearby Apple Maps results,
/// with "My Location" first when it is known.
struct DirectionsEndpointPicker: View {
    enum Which: Equatable {
        case origin, destination

        var title: String { self == .origin ? "From" : "To" }
    }

    let which: Which
    let userLocation: CLLocationCoordinate2D?
    let onPick: (DirectionsEndpoint) -> Void
    let onCancel: () -> Void

    @Query private var places: [Place]
    @State private var searchState = SearchState()
    @FocusState private var isFocused: Bool

    private var query: String { searchState.searchText.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField(which == .origin ? "Starting point" : "Destination", text: $searchState.searchText)
                        .focused($isFocused)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .accessibilityIdentifier("directions.endpointSearch")
                    if !searchState.searchText.isEmpty {
                        Button {
                            searchState.clearSearch()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 40)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))

                Button("Cancel", action: onCancel)
                    .font(.body)
            }

            if query.isEmpty {
                if let userLocation {
                    Button {
                        onPick(.userLocation(userLocation))
                    } label: {
                        SearchResultRow(icon: "location.fill", iconColor: .blue, iconShape: .circle,
                                        title: "My Location", subtitle: nil)
                    }
                    .buttonStyle(.plain)
                }
                Text("Search a place, stop or address")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            } else if searchState.hasAnyResults {
                VStack(alignment: .leading, spacing: 0) {
                    if let userLocation, "my location".hasPrefix(query.lowercased()) {
                        resultButton(.userLocation(userLocation), icon: "location.fill", color: .blue,
                                     shape: .circle, subtitle: nil)
                    }
                    ForEach(searchState.placeSearchResults.prefix(5)) { place in
                        let color = (place.layers ?? []).first.flatMap { Color(hex: $0.colorHex) } ?? .gray
                        resultButton(DirectionsEndpoint(name: place.name, coordinate: place.coordinate),
                                     icon: "mappin", color: color, shape: .circle, subtitle: "Saved place")
                    }
                    ForEach(searchState.transitSearchResults.prefix(5)) { stop in
                        resultButton(DirectionsEndpoint(name: stop.name, coordinate: stop.coordinate),
                                     icon: stop.kind.systemImage, color: TransitColors.pin(for: stop),
                                     shape: .rounded,
                                     subtitle: stop.code.map { "\(stop.kind.displayName) · Stop \($0)" } ?? stop.kind.displayName)
                    }
                    ForEach(Array(searchState.searchResults.prefix(8).enumerated()), id: \.offset) { _, item in
                        // `MKMapItem` is converted here; it is not Sendable.
                        resultButton(DirectionsEndpoint(name: item.name ?? "Place", coordinate: item.placemark.coordinate),
                                     icon: "magnifyingglass", color: .gray, shape: .circle,
                                     subtitle: [item.placemark.thoroughfare, item.placemark.locality]
                                        .compactMap { $0 }.joined(separator: ", "))
                    }
                }
            } else if searchState.isSearching {
                SkeletonRows(count: 3)
            } else {
                StatusView(status: .empty(title: "No matches for “\(query)”",
                                          hint: "Try a place name, stop number or street",
                                          systemImage: "magnifyingglass", action: nil))
            }
        }
        .onChange(of: searchState.searchText) { _, _ in
            searchState.debouncedSearch(places: places, transit: TransitLayerStore.shared,
                                        userLocation: userLocation)
        }
        .onAppear { isFocused = true }
    }

    private func resultButton(_ endpoint: DirectionsEndpoint, icon: String, color: Color,
                              shape: SearchResultRow.IconShape, subtitle: String?) -> some View {
        Button { onPick(endpoint) } label: {
            SearchResultRow(icon: icon, iconColor: color, iconShape: shape,
                            title: endpoint.name, subtitle: subtitle)
        }
        .buttonStyle(.plain)
        .accessibilityHint(which == .origin ? "Sets the starting point" : "Sets the destination")
    }
}

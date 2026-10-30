import SwiftUI
import SwiftData
import MapKit

struct PlaceDetailSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toastCenter: ToastCenter?
    @Query(sort: \Layer.sortOrder) private var allLayers: [Layer]
    @Bindable var place: Place
    /// Opens the directions sheet for this place (in place of this one).
    var onDirections: (DirectionsEndpoint) -> Void = { _ in }
    /// Opens a nearby stop's arrivals (in place of this sheet).
    var onOpenStop: (TransitStop) -> Void = { _ in }

    @State private var showEditForm = false
    /// Set when the user un-ticks the place's last layer.
    @State private var confirmDeleteOnLastLayer = false
    /// Set once the place is being deleted so the body stops reading it.
    @State private var isDeleting = false
    @State private var yelpBusiness: YelpBusiness?
    @State private var yelpReviews: [YelpReview] = []
    @State private var yelpStatus: InlineStatus?
    @State private var mapItem: MKMapItem?

    /// Every place layer the user could put this place in (never trails).
    private var placeKindLayers: [Layer] {
        allLayers.filter { $0.kind == .places }
    }

    private var memberLayerIds: Set<UUID> {
        Set((place.layers ?? []).map(\.id))
    }

    var body: some View {
        if isDeleting {
            Color.clear
        } else {
            content
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // --- Compact header ---
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(place.name)
                            .font(.title3.bold())

                        if place.rating > 0 {
                            RatingDisplayView(rating: place.rating)
                        }

                        // Open/closed from Yelp
                        if let biz = yelpBusiness, let isOpen = biz.isCurrentlyOpen {
                            Text(isOpen ? "Open now" : "Closed")
                                .font(.caption.bold())
                                .foregroundStyle(isOpen ? .green : .secondary)
                        }

                        if !place.tags.isEmpty {
                            Text(place.tags.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()
                }

                PlaceActionRow(name: place.name, coordinate: place.coordinate,
                               primaryTitle: "Edit", primarySystemImage: "pencil",
                               onPrimary: { showEditForm = true },
                               onDirections: {
                                   onDirections(DirectionsEndpoint(name: place.name, coordinate: place.coordinate))
                               })

                // Tags: tap to add or remove; pick two tags with Match All
                // in the layers panel to find places that have both.
                if !placeKindLayers.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tags")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                        LayerMembershipChips(layers: placeKindLayers,
                                             selected: memberLayerIds,
                                             onToggle: toggleMembership)
                    }
                }

                NearbyTransitSection(coordinate: place.coordinate, onOpenStop: onOpenStop)

                // --- Extended details ---
                Divider()

                // Address, phone, website from MapKit lookup
                if let item = mapItem {
                    let address = [item.placemark.subThoroughfare, item.placemark.thoroughfare, item.placemark.locality, item.placemark.administrativeArea]
                        .compactMap { $0 }.joined(separator: " ")
                    if !address.isEmpty {
                        Label(address, systemImage: "mappin.and.ellipse")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let phone = item.phoneNumber, !phone.isEmpty {
                        Label(phone, systemImage: "phone")
                            .font(.subheadline)
                    }
                    if let url = item.url {
                        Label(url.host ?? url.absoluteString, systemImage: "globe")
                            .font(.subheadline)
                            .foregroundStyle(.blue)
                    }
                    if let category = item.pointOfInterestCategory {
                        let catName = poiCategoryName(category)
                        if let catName {
                            Label(catName, systemImage: "tag")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    }
                }

                // Yelp rating
                if let biz = yelpBusiness, let rating = biz.rating, let count = biz.reviewCount {
                    HStack(spacing: 4) {
                        yelpStars(rating: rating)
                        Text(String(format: "%.1f", rating))
                            .font(.subheadline.bold())
                        Text("(\(count) reviews)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Hours
                if !place.hoursInfo.isEmpty {
                    Label(place.hoursInfo, systemImage: "clock")
                        .font(.subheadline)
                } else if let hours = yelpBusiness?.todayHours {
                    Label("Today: \(hours)", systemImage: "clock")
                        .font(.subheadline)
                }

                // Notes
                if !place.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notes")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                        Text(place.notes)
                            .font(.subheadline)
                    }
                }

                // Photos (saved)
                if !place.photoData.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Photos")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(place.photoData.indices, id: \.self) { idx in
                                    if let img = UIImage(data: place.photoData[idx]) {
                                        Image(uiImage: img)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 140, height: 100)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                            }
                        }
                    }
                }

                // Yelp photos
                if let photos = yelpBusiness?.photos, !photos.isEmpty, place.photoData.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Photos")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(photos, id: \.self) { urlStr in
                                    AsyncImage(url: URL(string: urlStr)) { image in
                                        image.resizable().scaledToFill()
                                            .frame(width: 140, height: 100)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    } placeholder: {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.gray.opacity(0.2))
                                            .frame(width: 140, height: 100)
                                            .overlay(ProgressView())
                                    }
                                }
                            }
                        }
                    }
                }

                // Yelp reviews
                if !yelpReviews.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Reviews")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                        ForEach(yelpReviews, id: \.id) { review in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    yelpStars(rating: Double(review.rating))
                                    Text(review.user.name)
                                        .font(.caption.bold())
                                }
                                Text(review.text)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                            .padding(10)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }

                if let yelpStatus {
                    StatusView(status: yelpStatus) { _ in
                        Task { await loadYelpData() }
                    }
                }
            }
            .padding(.horizontal)
            // Clears the system drag indicator, the sheet's only grabber.
            .padding(.top, 20)
            .padding(.bottom)
        }
        .task {
            await loadMapItem()
            await loadYelpData()
        }
        .sheet(isPresented: $showEditForm) {
            PlaceFormView(place: place)
        }
        .confirmationDialog("Remove its last tag?", isPresented: $confirmDeleteOnLastLayer,
                            titleVisibility: .visible) {
            Button("Delete place", role: .destructive, action: deletePlace)
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The place will be deleted.")
        }
    }

    // MARK: - Layers

    /// Adds or removes the place from `layer` right away. Un-ticking its
    /// only layer would orphan it, so that asks to delete instead.
    private func toggleMembership(_ layer: Layer) {
        if place.isMember(of: layer) {
            guard (place.layers ?? []).count > 1 else {
                confirmDeleteOnLastLayer = true
                return
            }
            place.removeMembership(layer)
        } else {
            place.addMembership(layer)
        }
        try? modelContext.save()
    }

    private func deletePlace() {
        let name = place.name
        isDeleting = true
        modelContext.delete(place)
        try? modelContext.save()
        toastCenter?.show("Deleted \(name)", systemImage: "trash")
        dismiss()
    }

    private func loadMapItem() async {
        // Reverse lookup to get MapKit business data (phone, website, category)
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = place.name
        request.region = MKCoordinateRegion(
            center: place.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
        )
        let search = MKLocalSearch(request: request)
        if let response = try? await search.start(),
           let item = response.mapItems.first {
            mapItem = item
        }
    }

    private func poiCategoryName(_ category: MKPointOfInterestCategory) -> String? {
        switch category {
        case .restaurant: return "Restaurant"
        case .cafe: return "Cafe"
        case .bakery: return "Bakery"
        case .store: return "Store"
        case .hotel: return "Hotel"
        case .gasStation: return "Gas Station"
        case .hospital: return "Hospital"
        case .pharmacy: return "Pharmacy"
        case .park: return "Park"
        case .fitnessCenter: return "Gym"
        case .nightlife: return "Nightlife"
        case .brewery: return "Brewery"
        case .bank: return "Bank"
        case .foodMarket: return "Food Market"
        default: return nil
        }
    }

    private func loadYelpData() async {
        guard YelpService.isConfigured else { return }
        yelpStatus = .loading("Loading reviews…")
        switch await YelpService().lookup(name: place.name, coordinate: place.coordinate) {
        case .found(let business, let reviews):
            yelpBusiness = business
            yelpReviews = reviews
            yelpStatus = nil
        case .noMatch:
            yelpStatus = nil
        case .failed:
            yelpStatus = .failed(message: "Couldn't load reviews right now", retryId: "yelp")
        }
    }

    @ViewBuilder
    private func yelpStars(rating: Double) -> some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: Double(i) <= rating ? "star.fill" : (Double(i) - 0.5 <= rating ? "star.leadinghalf.filled" : "star"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }
}

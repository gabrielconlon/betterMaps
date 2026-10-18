import SwiftUI
import SwiftData
import MapKit

struct POIAddToLayerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Layer.sortOrder) private var layers: [Layer]

    let mapItem: MKMapItem
    let onDismiss: () -> Void

    init(mapItem: MKMapItem, onDismiss: @escaping () -> Void) {
        self.mapItem = mapItem
        self.onDismiss = onDismiss
    }

    @State private var showAddToLayer = false
    /// The transit stop this POI stands for (nearest via the stop grid);
    /// non-nil presents the arrivals sheet.
    @State private var nearbyStop: TransitStop?
    @State private var arrivalsStop: TransitStop?
    @State private var yelpBusiness: YelpBusiness?
    @State private var yelpReviews: [YelpReview] = []
    @State private var yelpStatus: InlineStatus?

    var isTransitPOI: Bool {
        guard let cat = mapItem.pointOfInterestCategory else { return false }
        return cat == .publicTransport || cat == .airport
    }

    var placeName: String {
        mapItem.name ?? "Unknown Place"
    }

    var fullAddress: String {
        let pm = mapItem.placemark
        return [pm.subThoroughfare, pm.thoroughfare, pm.locality, pm.administrativeArea, pm.postalCode]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    var categoryName: String? {
        guard let category = mapItem.pointOfInterestCategory else { return nil }
        return poiCategoryDisplayName(category)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Drag indicator
                HStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 40, height: 5)
                    Spacer()
                }
                .padding(.top, 8)

                // --- Compact header (visible at small detent) ---
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(placeName)
                            .font(.title3.bold())

                        if let category = categoryName {
                            Label(category, systemImage: poiCategoryIcon(mapItem.pointOfInterestCategory))
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }

                        // Open/closed status from Yelp
                        if let biz = yelpBusiness {
                            if let isOpen = biz.isCurrentlyOpen {
                                Text(isOpen ? "Open now" : "Closed")
                                    .font(.caption.bold())
                                    .foregroundStyle(isOpen ? .green : .secondary)
                            }
                            if let price = biz.price {
                                Text(price)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if !fullAddress.isEmpty {
                            Text(fullAddress)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()
                }

                PlaceActionRow(name: placeName, coordinate: mapItem.placemark.coordinate,
                               primaryTitle: "Add tags", primarySystemImage: "tag",
                               onPrimary: { showAddToLayer = true },
                               extra: arrivalsAction)

                // --- Extended details (visible when swiped up) ---

                Divider()

                // Yelp rating
                if let biz = yelpBusiness {
                    if let rating = biz.rating, let count = biz.reviewCount {
                        HStack(spacing: 4) {
                            yelpStars(rating: rating)
                            Text(String(format: "%.1f", rating))
                                .font(.subheadline.bold())
                            Text("(\(count) reviews)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Hours
                if let todayHours = yelpBusiness?.todayHours {
                    Label("Today: \(todayHours)", systemImage: "clock")
                        .font(.subheadline)
                }

                // Phone
                if let phone = yelpBusiness?.displayPhone ?? mapItem.phoneNumber, !phone.isEmpty {
                    Label(phone, systemImage: "phone")
                        .font(.subheadline)
                }

                // Website
                if let url = mapItem.url {
                    Label(url.host ?? url.absoluteString, systemImage: "globe")
                        .font(.subheadline)
                        .foregroundStyle(.blue)
                }

                // Photos from Yelp
                if let photos = yelpBusiness?.photos, !photos.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Photos")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(photos, id: \.self) { urlString in
                                    AsyncImage(url: URL(string: urlString)) { image in
                                        image
                                            .resizable()
                                            .scaledToFill()
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

                // Reviews from Yelp
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
                                    Spacer()
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
            .padding(.bottom)
        }
        .task {
            await loadYelpData()
        }
        .task {
            guard isTransitPOI else { return }
            let store = TransitLayerStore.shared
            await store.loadIfNeeded()
            nearbyStop = store.nearestStop(to: mapItem.placemark.coordinate)
        }
        .sheet(item: $arrivalsStop) { stop in
            TransitArrivalsView(stop: stop)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showAddToLayer) {
            AddToLayerSheet(
                mapItem: mapItem,
                yelpBusiness: yelpBusiness,
                categoryName: categoryName,
                onSaved: {
                    onDismiss()
                    dismiss()
                }
            )
        }
    }

    /// "Arrivals" for a transit POI once its stop is resolved.
    private var arrivalsAction: PlaceActionRow.Extra? {
        guard isTransitPOI, let nearbyStop else { return nil }
        return PlaceActionRow.Extra(title: "Arrivals", systemImage: "clock") { arrivalsStop = nearbyStop }
    }

    // MARK: - Yelp

    private func loadYelpData() async {
        guard YelpService.isConfigured else { return }
        yelpStatus = .loading("Loading reviews…")
        switch await YelpService().lookup(name: placeName, coordinate: mapItem.placemark.coordinate) {
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

    // MARK: - POI Category Helpers

    private func poiCategoryDisplayName(_ category: MKPointOfInterestCategory?) -> String? {
        guard let category else { return nil }
        switch category {
        case .restaurant: return "Restaurant"
        case .cafe: return "Cafe"
        case .bakery: return "Bakery"
        case .store: return "Store"
        case .hotel: return "Hotel"
        case .gasStation: return "Gas Station"
        case .parking: return "Parking"
        case .hospital: return "Hospital"
        case .pharmacy: return "Pharmacy"
        case .school: return "School"
        case .university: return "University"
        case .library: return "Library"
        case .museum: return "Museum"
        case .theater: return "Theater"
        case .park: return "Park"
        case .beach: return "Beach"
        case .fitnessCenter: return "Gym"
        case .nightlife: return "Nightlife"
        case .brewery: return "Brewery"
        case .winery: return "Winery"
        case .airport: return "Airport"
        case .publicTransport: return "Public Transit"
        case .bank: return "Bank"
        case .postOffice: return "Post Office"
        case .laundry: return "Laundry"
        case .foodMarket: return "Food Market"
        default: return "Point of Interest"
        }
    }

    private func poiCategoryIcon(_ category: MKPointOfInterestCategory?) -> String {
        guard let category else { return "mappin" }
        switch category {
        case .restaurant, .cafe, .bakery: return "fork.knife"
        case .store, .foodMarket: return "bag.fill"
        case .hotel: return "bed.double.fill"
        case .gasStation: return "fuelpump.fill"
        case .parking: return "p.circle.fill"
        case .hospital, .pharmacy: return "cross.case.fill"
        case .school, .university: return "graduationcap.fill"
        case .library: return "book.fill"
        case .museum: return "building.columns.fill"
        case .theater: return "theatermasks.fill"
        case .park, .beach: return "leaf.fill"
        case .fitnessCenter: return "figure.run"
        case .nightlife, .brewery, .winery: return "wineglass.fill"
        case .airport: return "airplane"
        case .publicTransport: return "bus.fill"
        case .bank: return "banknote.fill"
        default: return "mappin"
        }
    }
}

// MARK: - Add to Layer Sheet (with Create Layer option)

/// Picks the place layers a POI goes in. If the POI is already saved (same
/// name within 30 m, or anything within 8 m) it edits that place's layers
/// instead of inserting a duplicate, so saving a restaurant to Brunch and
/// then Favourites makes one place in both: an overlap.
struct AddToLayerSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toastCenter: ToastCenter?
    @Query(sort: \Layer.sortOrder) private var layers: [Layer]
    @Query private var places: [Place]

    let mapItem: MKMapItem
    let yelpBusiness: YelpBusiness?
    let categoryName: String?
    let onSaved: () -> Void

    @State private var notes: String = ""
    @State private var rating: Int = 0
    @State private var selectedLayerIDs: Set<UUID> = []
    @State private var showCreateLayer = false
    /// The saved place this POI already is, resolved once on appear.
    @State private var existingPlace: Place?
    @State private var didResolve = false

    /// Tags only; trail groups are never offered.
    private var placeLayers: [Layer] { layers.filter { $0.kind == .places } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if placeLayers.isEmpty {
                        Text("No tags yet. Create one below.")
                            .foregroundStyle(.secondary)
                    } else {
                        LayerMembershipChips(layers: placeLayers, selected: selectedLayerIDs) { layer in
                            toggleLayer(layer)
                        }
                        .padding(.vertical, 4)
                    }

                    Button(action: { showCreateLayer = true }) {
                        Label("New tag", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Tags")
                } footer: {
                    if existingPlace != nil {
                        Text("Already saved. Add more tags to find it with Match All.")
                    }
                }

                if existingPlace == nil {
                    Section("Personal Notes (optional)") {
                        RatingView(rating: $rating)
                        TextField("Notes about this place...", text: $notes, axis: .vertical)
                            .lineLimit(3)
                    }
                }
            }
            .navigationTitle("Add tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existingPlace == nil ? "Add" : "Save") { savePlace() }
                        .disabled(selectedLayerIDs.isEmpty)
                        .bold()
                }
            }
            .sheet(isPresented: $showCreateLayer) {
                LayerFormView(layer: nil)
            }
            .onAppear(perform: resolveExisting)
        }
    }

    private func toggleLayer(_ layer: Layer) {
        if selectedLayerIDs.contains(layer.id) {
            selectedLayerIDs.remove(layer.id)
        } else {
            selectedLayerIDs.insert(layer.id)
        }
    }

    /// Finds the already-saved place, if any, and ticks its tags.
    private func resolveExisting() {
        guard !didResolve else { return }
        didResolve = true
        let lites = PlaceMatcher.candidates(places.map(PlaceLite.init), layers: layers.map(LayerLite.init))
        guard let id = PlaceMatcher.match(name: mapItem.name ?? "",
                                          coordinate: mapItem.placemark.coordinate,
                                          among: lites),
              let place = places.first(where: { $0.id == id }) else { return }
        existingPlace = place
        selectedLayerIDs = Set((place.layers ?? []).filter { $0.kind == .places }.map(\.id))
    }

    private func savePlace() {
        let chosen = placeLayers.filter { selectedLayerIDs.contains($0.id) }
        if let existingPlace {
            let added = chosen.filter { !existingPlace.isMember(of: $0) }
            for layer in placeLayers {
                if selectedLayerIDs.contains(layer.id) {
                    existingPlace.addMembership(layer)
                } else {
                    existingPlace.removeMembership(layer)
                }
            }
            try? modelContext.save()
            toastCenter?.show(added.isEmpty ? "Tags updated"
                                            : "Tagged " + added.map(\.name).joined(separator: " + "))
        } else {
            insertPlace(into: chosen)
        }
        onSaved()
        dismiss()
    }

    private func insertPlace(into chosen: [Layer]) {
        let coordinate = mapItem.placemark.coordinate
        var tags: [String] = []
        if let category = categoryName { tags.append(category) }
        if let price = yelpBusiness?.price { tags.append(price) }
        if let cats = yelpBusiness?.categories {
            tags.append(contentsOf: cats.map { $0.title })
        }

        let newPlace = Place(
            name: mapItem.name ?? "Unknown",
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            notes: notes,
            rating: rating > 0 ? rating : Int(yelpBusiness?.rating ?? 0),
            hoursInfo: yelpBusiness?.todayHours ?? "",
            tags: Array(Set(tags)) // deduplicate
        )
        modelContext.insert(newPlace)
        for layer in chosen { newPlace.addMembership(layer) }
        try? modelContext.save()

        let context = modelContext
        toastCenter?.show(PlaceFormView.savedMessage(layerNames: chosen.map(\.name)),
                          action: ToastAction(label: "Undo") {
                              context.delete(newPlace)
                              try? context.save()
                          },
                          duration: .seconds(4))
    }
}

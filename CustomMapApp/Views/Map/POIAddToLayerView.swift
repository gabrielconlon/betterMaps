import SwiftUI
import SwiftData
import MapKit

struct POIAddToLayerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Layer.sortOrder) private var layers: [Layer]

    let mapItem: MKMapItem
    let onDismiss: () -> Void
    let onGetDirections: ((MKMapItem) -> Void)?

    init(mapItem: MKMapItem, onGetDirections: ((MKMapItem) -> Void)? = nil, onDismiss: @escaping () -> Void) {
        self.mapItem = mapItem
        self.onGetDirections = onGetDirections
        self.onDismiss = onDismiss
    }

    @State private var showAddToLayer = false
    @State private var yelpBusiness: YelpBusiness?
    @State private var yelpReviews: [YelpReview] = []
    @State private var isLoadingYelp = false

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
                                Text(isOpen ? "Open Now" : "Closed")
                                    .font(.caption.bold())
                                    .foregroundStyle(isOpen ? .green : .red)
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

                    HStack(spacing: 10) {
                        Button(action: { showAddToLayer = true }) {
                            Image(systemName: "plus.circle.fill")
                                .font(.title)
                                .foregroundStyle(.blue)
                        }
                        Button(action: {
                            onGetDirections?(mapItem)
                            onDismiss()
                            dismiss()
                        }) {
                            Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                                .font(.title)
                                .foregroundStyle(.green)
                        }
                    }
                }

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

                if isLoadingYelp {
                    HStack {
                        Spacer()
                        ProgressView("Loading details...")
                            .font(.caption)
                        Spacer()
                    }
                }

                if !YelpService.isConfigured {
                    Text("Add a Yelp API key in Settings for hours, photos & reviews.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }

                // Action buttons
                HStack(spacing: 12) {
                    Button(action: { showAddToLayer = true }) {
                        Label("Add to Layer", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: {
                        onGetDirections?(mapItem)
                        onDismiss()
                        dismiss()
                    }) {
                        Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }

                Button(action: {
                    let placemark = MKPlacemark(coordinate: mapItem.placemark.coordinate)
                    let item = MKMapItem(placemark: placemark)
                    item.name = placeName
                    item.openInMaps()
                }) {
                    Label("Open in Apple Maps", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .task {
            await loadYelpData()
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

    // MARK: - Yelp

    private func loadYelpData() async {
        guard YelpService.isConfigured else { return }
        isLoadingYelp = true
        let service = YelpService()
        if let biz = await service.searchBusiness(
            name: placeName,
            coordinate: mapItem.placemark.coordinate
        ) {
            yelpBusiness = biz
            yelpReviews = await service.fetchReviews(businessId: biz.id)
        }
        isLoadingYelp = false
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

struct AddToLayerSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Layer.sortOrder) private var layers: [Layer]

    let mapItem: MKMapItem
    let yelpBusiness: YelpBusiness?
    let categoryName: String?
    let onSaved: () -> Void

    @State private var notes: String = ""
    @State private var rating: Int = 0
    @State private var selectedLayerIDs: Set<UUID> = []
    @State private var showCreateLayer = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Select Layers") {
                    if layers.isEmpty {
                        Text("No layers yet — create one below.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(layers) { layer in
                            Button(action: { toggleLayer(layer) }) {
                                HStack {
                                    Image(systemName: layer.symbolName)
                                        .foregroundStyle(Color(hex: layer.colorHex) ?? .red)
                                        .frame(width: 24)
                                    Text(layer.name)
                                    Spacer()
                                    if selectedLayerIDs.contains(layer.id) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.blue)
                                    } else {
                                        Image(systemName: "circle")
                                            .foregroundStyle(.gray.opacity(0.4))
                                    }
                                }
                            }
                            .tint(.primary)
                        }
                    }

                    Button(action: { showCreateLayer = true }) {
                        Label("Create New Layer", systemImage: "plus.circle")
                    }
                }

                Section("Personal Notes (optional)") {
                    RatingView(rating: $rating)
                    TextField("Notes about this place...", text: $notes, axis: .vertical)
                        .lineLimit(3)
                }
            }
            .navigationTitle("Add to Layer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { savePlace() }
                        .disabled(selectedLayerIDs.isEmpty)
                        .bold()
                }
            }
            .sheet(isPresented: $showCreateLayer) {
                LayerFormView(layer: nil)
            }
        }
    }

    private func toggleLayer(_ layer: Layer) {
        if selectedLayerIDs.contains(layer.id) {
            selectedLayerIDs.remove(layer.id)
        } else {
            selectedLayerIDs.insert(layer.id)
        }
    }

    private func savePlace() {
        let coordinate = mapItem.placemark.coordinate
        var tags: [String] = []
        if let category = categoryName { tags.append(category) }
        if let price = yelpBusiness?.price { tags.append(price) }
        if let cats = yelpBusiness?.categories {
            tags.append(contentsOf: cats.map { $0.title })
        }

        var hoursInfo = ""
        if let hours = yelpBusiness?.todayHours {
            hoursInfo = hours
        }

        let newPlace = Place(
            name: mapItem.name ?? "Unknown",
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            notes: notes,
            rating: rating > 0 ? rating : Int(yelpBusiness?.rating ?? 0),
            hoursInfo: hoursInfo,
            tags: Array(Set(tags)) // deduplicate
        )
        modelContext.insert(newPlace)

        for layer in layers where selectedLayerIDs.contains(layer.id) {
            if layer.places == nil { layer.places = [] }
            layer.places?.append(newPlace)
        }

        onSaved()
        dismiss()
    }
}

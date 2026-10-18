import SwiftUI
import SwiftData
import MapKit

struct PlaceDetailSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Layer.sortOrder) private var allLayers: [Layer]
    @Bindable var place: Place

    @State private var showEditForm = false
    @State private var showAddToLayer = false
    @State private var yelpBusiness: YelpBusiness?
    @State private var yelpReviews: [YelpReview] = []
    @State private var isLoadingYelp = false
    @State private var mapItem: MKMapItem?

    var placeLayers: [Layer] {
        (place.layers ?? []).sorted { $0.sortOrder < $1.sortOrder }
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
                            Text(isOpen ? "Open Now" : "Closed")
                                .font(.caption.bold())
                                .foregroundStyle(isOpen ? .green : .red)
                        }

                        if !place.tags.isEmpty {
                            Text(place.tags.joined(separator: " · "))
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
                        Button(action: openInAppleMaps) {
                            Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                                .font(.title)
                                .foregroundStyle(.green)
                        }
                    }
                }

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

                // Layers this place belongs to
                if !placeLayers.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("In Layers")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                        ForEach(placeLayers) { layer in
                            HStack(spacing: 8) {
                                Image(systemName: layer.symbolName)
                                    .foregroundStyle(Color(hex: layer.colorHex) ?? .red)
                                    .frame(width: 20)
                                Text(layer.name)
                                    .font(.subheadline)
                            }
                        }
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

                if isLoadingYelp {
                    HStack { Spacer(); ProgressView("Loading details...").font(.caption); Spacer() }
                }

                // Action buttons
                HStack(spacing: 12) {
                    Button(action: { showAddToLayer = true }) {
                        Label("Add to Layer", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: openInAppleMaps) {
                        Label("Open in Apple Maps", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }

                Button(action: { showEditForm = true }) {
                    Label("Edit", systemImage: "pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .task {
            await loadMapItem()
            await loadYelpData()
        }
        .sheet(isPresented: $showEditForm) {
            PlaceFormView(place: place)
        }
        .sheet(isPresented: $showAddToLayer) {
            SavedPlaceLayerSheet(place: place)
        }
    }

    /// Hand off to Apple Maps with walking directions to this place.
    private func openInAppleMaps() {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: place.coordinate))
        item.name = place.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
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
        isLoadingYelp = true
        let service = YelpService()
        if let biz = await service.searchBusiness(
            name: place.name,
            coordinate: place.coordinate
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
}

// MARK: - Manage layers for an existing saved place

struct SavedPlaceLayerSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Layer.sortOrder) private var allLayers: [Layer]
    @Bindable var place: Place

    @State private var showCreateLayer = false

    var placeLayerIDs: Set<UUID> {
        Set((place.layers ?? []).map { $0.id })
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Current Layers") {
                    if placeLayerIDs.isEmpty {
                        Text("Not in any layers yet.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("All Layers") {
                    ForEach(allLayers) { layer in
                        Button(action: { toggleLayer(layer) }) {
                            HStack {
                                Image(systemName: layer.symbolName)
                                    .foregroundStyle(Color(hex: layer.colorHex) ?? .red)
                                    .frame(width: 24)
                                Text(layer.name)
                                Spacer()
                                if placeLayerIDs.contains(layer.id) {
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

                    Button(action: { showCreateLayer = true }) {
                        Label("Create New Layer", systemImage: "plus.circle")
                    }
                }
            }
            .navigationTitle("Manage Layers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showCreateLayer) {
                LayerFormView(layer: nil)
            }
        }
    }

    private func toggleLayer(_ layer: Layer) {
        if placeLayerIDs.contains(layer.id) {
            // Remove from layer
            layer.places?.removeAll { $0.id == place.id }
        } else {
            // Add to layer
            if layer.places == nil { layer.places = [] }
            layer.places?.append(place)
        }
    }
}

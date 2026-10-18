import SwiftUI
import PhotosUI

struct PhotoPickerView: View {
    @Binding var photoData: [Data]
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var isProcessing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Existing photos
            if !photoData.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(photoData.indices, id: \.self) { index in
                            if let uiImage = UIImage(data: photoData[index]) {
                                ZStack(alignment: .topTrailing) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 100, height: 75)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))

                                    Button(action: {
                                        photoData.remove(at: index)
                                    }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.white, .red)
                                            .frame(width: 44, height: 44, alignment: .topTrailing)
                                            .contentShape(Rectangle())
                                    }
                                    .accessibilityLabel("Remove photo \(index + 1)")
                                    .offset(x: 4, y: -4)
                                }
                            }
                        }
                    }
                }
            }

            // Picker. The label's closure is `@Sendable`, so it gets a plain
            // String computed here on the main actor, not `photoData` itself.
            let pickerTitle = photoData.isEmpty ? "Add Photos" : "Add More"
            PhotosPicker(
                selection: $selectedItems,
                maxSelectionCount: 5,
                matching: .images
            ) {
                Label(pickerTitle, systemImage: "photo.badge.plus")
            }
            .onChange(of: selectedItems) { _, newItems in
                guard !newItems.isEmpty else { return }
                Task { @MainActor in
                    isProcessing = true
                    for item in newItems {
                        guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                        // Compress to JPEG off the main actor, then append on it.
                        if let compressed = await Self.compressed(data) {
                            photoData.append(compressed)
                        }
                    }
                    selectedItems = []
                    isProcessing = false
                }
            }

            if isProcessing {
                ProgressView("Processing photos...")
                    .font(.caption)
            }
        }
    }

    /// JPEG at 0.7 quality for storage efficiency; nil if not an image.
    private nonisolated static func compressed(_ data: Data) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            UIImage(data: data)?.jpegData(compressionQuality: 0.7)
        }.value
    }
}

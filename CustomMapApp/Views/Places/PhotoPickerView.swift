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
                                    }
                                    .offset(x: 4, y: -4)
                                }
                            }
                        }
                    }
                }
            }

            // Picker
            PhotosPicker(
                selection: $selectedItems,
                maxSelectionCount: 5,
                matching: .images
            ) {
                Label(
                    photoData.isEmpty ? "Add Photos" : "Add More",
                    systemImage: "photo.badge.plus"
                )
            }
            .onChange(of: selectedItems) { _, newItems in
                Task {
                    isProcessing = true
                    for item in newItems {
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            // Compress to JPEG for storage efficiency
                            if let uiImage = UIImage(data: data),
                               let compressed = uiImage.jpegData(compressionQuality: 0.7) {
                                photoData.append(compressed)
                            }
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
}

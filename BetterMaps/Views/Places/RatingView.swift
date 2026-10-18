import SwiftUI

struct RatingView: View {
    @Binding var rating: Int
    var maxRating: Int = 5

    var body: some View {
        HStack(spacing: 0) {
            ForEach(1...maxRating, id: \.self) { index in
                Button {
                    rating = index == rating ? 0 : index
                } label: {
                    Image(systemName: index <= rating ? "star.fill" : "star")
                        .foregroundStyle(index <= rating ? .yellow : .gray.opacity(0.4))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(.title3)
        .sensoryFeedback(.selection, trigger: rating)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rating")
        .accessibilityValue(rating == 0 ? "Not rated" : "\(rating) of \(maxRating) stars")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: rating = min(maxRating, rating + 1)
            case .decrement: rating = max(0, rating - 1)
            @unknown default: break
            }
        }
    }
}

struct RatingDisplayView: View {
    let rating: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { index in
                Image(systemName: index <= rating ? "star.fill" : "star")
                    .foregroundStyle(index <= rating ? .yellow : .gray.opacity(0.4))
                    .font(.caption)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rating == 0 ? "Not rated" : "\(rating) of 5 stars")
    }
}

import SwiftUI

/// Zoom level thresholds for annotation sizing
enum AnnotationSize: Sendable, Equatable {
    case dot       // Far zoom — small colored dot
    case compact   // Medium zoom — small icon, no label
    case full      // Close zoom — full pin with icon and pointer

    init(latitudeDelta: Double) {
        if latitudeDelta > 0.08 {
            self = .dot
        } else if latitudeDelta > 0.02 {
            self = .compact
        } else {
            self = .full
        }
    }
}

/// A saved-place pin. Pure value inputs — no SwiftData walking — so the map
/// content can be built from `MapContentStore.output` alone.
///
/// Every size is tappable with a hit target of at least 24pt. Places shared
/// by two or more visible layers (`matchCount >= 2`) get a white ring, a
/// dark outer stroke and a dark count badge; the pin keeps its primary layer
/// colour. Black-and-white reads as "overlap" whatever the layer or transit
/// colours around it (accent blue was indistinguishable from Bus blue).
struct PlaceAnnotationView: View {
    let color: Color
    let symbol: String
    let name: String
    let matchCount: Int
    let size: AnnotationSize

    private var isOverlap: Bool { matchCount >= 2 }

    var body: some View {
        switch size {
        case .dot: dotView
        case .compact: compactView
        case .full: fullView
        }
    }

    // MARK: - Dot (far zoom): 12pt circle in a 24pt hit area

    private var dotView: some View {
        Circle()
            .fill(color)
            .frame(width: 12, height: 12)
            .overlay { if isOverlap { overlapRing } }
            .frame(width: 24, height: 24)
            .contentShape(Circle())
    }

    // MARK: - Compact (medium zoom): 24pt

    private var compactView: some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(color)
            .clipShape(Circle())
            .overlay { if isOverlap { overlapRing } }
            .overlay(alignment: .topTrailing) { if isOverlap { countBadge.offset(x: 5, y: -5) } }
            .contentShape(Circle().inset(by: -4))
    }

    // MARK: - Full (close zoom): 44pt pin + pointer

    private var fullView: some View {
        VStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(color)
                .clipShape(Circle())
                .overlay { if isOverlap { overlapRing } }
                .overlay(alignment: .topTrailing) { if isOverlap { countBadge.offset(x: 6, y: -6) } }
                .shadow(color: color.opacity(0.4), radius: 4, y: 2)
                .frame(minWidth: 44, minHeight: 44)

            Image(systemName: "triangle.fill")
                .font(.system(size: 8))
                .foregroundStyle(color)
                .rotationEffect(.degrees(180))
                .offset(y: -3)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Overlap treatment

    /// Fixed near-black so the ring and badge contrast in light and dark mode.
    private static let overlapInk = Color(white: 0.12)

    /// 2.5pt white ring with a dark stroke outside it.
    private var overlapRing: some View {
        Circle()
            .strokeBorder(.white, lineWidth: 2.5)
            .overlay { Circle().stroke(Self.overlapInk, lineWidth: 1.5).padding(-1.5) }
    }

    private var countBadge: some View {
        Text("\(matchCount)")
            .font(.caption2.bold())
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 3)
            .frame(minWidth: 16, minHeight: 16)
            .background(Self.overlapInk, in: Capsule())
            .overlay { Capsule().stroke(.white, lineWidth: 1) }
            // Grows with Dynamic Type, capped so it never swallows the pin.
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .accessibilityHidden(true)
    }
}

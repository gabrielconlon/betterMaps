import SwiftUI
import UIKit

// MARK: - Detents + layout (pure)

/// Resting heights of the persistent map sheet.
enum SheetDetent: Int, CaseIterable, Comparable, Sendable {
    case collapsed, medium, expanded

    static func < (lhs: SheetDetent, rhs: SheetDetent) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Grabber tap: collapsed → medium → expanded → collapsed.
    var cycled: SheetDetent {
        switch self {
        case .collapsed: return .medium
        case .medium: return .expanded
        case .expanded: return .collapsed
        }
    }

    var accessibilityValue: String {
        switch self {
        case .collapsed: return "Collapsed"
        case .medium: return "Half height"
        case .expanded: return "Full height"
        }
    }
}

/// Detent heights for a container, measured from the bottom of the screen
/// (bottom safe area included), plus drag-release snapping.
struct SheetLayout: Equatable, Sendable {
    /// Grabber strip + search row + chip row, above the bottom safe area.
    static let collapsedContentHeight: CGFloat = 100
    /// Release velocity (pt/s) above which a drag counts as a flick.
    static let flickVelocity: CGFloat = 700

    let collapsed: CGFloat
    let medium: CGFloat
    let expanded: CGFloat

    /// - Parameters:
    ///   - availableHeight: height from the top safe-area edge to the bottom
    ///     of the screen (or the top of the keyboard).
    ///   - bottomInset: home-indicator inset the sheet extends under.
    init(availableHeight: CGFloat, bottomInset: CGFloat) {
        let h = max(availableHeight, 0)
        collapsed = Self.collapsedContentHeight + bottomInset
        expanded = max(collapsed, min(h * 0.92, h - 24))
        medium = min(max(collapsed, h * 0.45), expanded)
    }

    func height(for detent: SheetDetent) -> CGFloat {
        switch detent {
        case .collapsed: return collapsed
        case .medium: return medium
        case .expanded: return expanded
        }
    }

    /// Detent to settle on after a vertical drag released at `translation`
    /// (positive = downward) with `velocity` (pt/s, positive = downward).
    /// A flick moves to the next detent in its direction from where the
    /// finger let go; a slow release settles on the nearest detent.
    func snap(from start: SheetDetent, translation: CGFloat, velocity: CGFloat) -> SheetDetent {
        let current = min(max(height(for: start) - translation, collapsed), expanded)
        if velocity <= -Self.flickVelocity {
            return SheetDetent.allCases.first { height(for: $0) > current + 1 } ?? .expanded
        }
        if velocity >= Self.flickVelocity {
            return SheetDetent.allCases.last { height(for: $0) < current - 1 } ?? .collapsed
        }
        return SheetDetent.allCases.min { abs(height(for: $0) - current) < abs(height(for: $1) - current) } ?? start
    }
}

// MARK: - View

/// Persistent Apple-Maps-style bottom sheet that lives in the screen's
/// ZStack (not a system sheet, so `.sheet(item:)` stays free for the router).
/// Everything above the sheet passes touches through to the map.
struct BottomSheet<Header: View, Content: View>: View {
    @Binding var detent: SheetDetent
    /// Settled sheet height above the bottom safe area; fires when the detent
    /// or container changes, never per drag frame.
    var onSettledHeightChange: (CGFloat) -> Void = { _ in }
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragTranslation: CGFloat = 0
    @State private var dragAxis: Axis?

    private static var cornerRadius: CGFloat { 14 }

    private var animation: Animation? {
        reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.86)
    }

    var body: some View {
        GeometryReader { geo in
            let bottomInset = Self.homeIndicatorInset(containerHeight: geo.size.height)
            let layout = SheetLayout(availableHeight: geo.size.height, bottomInset: bottomInset)
            let base = layout.height(for: detent)
            let height = rubberBanded(base - dragTranslation, layout: layout)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                sheet(height: height, bottomInset: bottomInset, layout: layout)
            }
            .onChange(of: base - bottomInset, initial: true) { _, settled in
                onSettledHeightChange(settled)
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private func sheet(height: CGFloat, bottomInset: CGFloat, layout: SheetLayout) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: Self.cornerRadius,
                                           topTrailingRadius: Self.cornerRadius)
        return VStack(spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 36, height: 5)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, minHeight: 12, alignment: .top)

            VStack(spacing: 0) {
                header()
            }
            .contentShape(Rectangle())
            .simultaneousGesture(dragGesture(layout: layout))

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .scrollDisabled(detent == .collapsed)
                .opacity(detent == .collapsed && dragTranslation >= 0 ? 0 : 1)
                .allowsHitTesting(detent != .collapsed)
                .accessibilityHidden(detent == .collapsed)
        }
        .padding(.bottom, bottomInset)
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .top)
        // Shadow on the background shape only: shadowing the whole sheet
        // would composite the content offscreen and wash out the vibrant
        // `.secondary` text drawn over the material. The inner ScrollView
        // clips itself, so no clipShape is needed either.
        .background {
            shape
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.15), radius: 10, y: -2)
        }
        .overlay(alignment: .top) { grabberHitArea(layout: layout) }
        .animation(animation, value: detent)
    }

    /// 44pt-tall grabber target centred on the sheet's top edge. Tap cycles
    /// detents; VoiceOver can adjust it like a stepper.
    private func grabberHitArea(layout: SheetLayout) -> some View {
        Color.clear
            .frame(width: 120, height: 44)
            .contentShape(Rectangle())
            .offset(y: -16)
            .onTapGesture { setDetent(detent.cycled) }
            .gesture(dragGesture(layout: layout))
            .accessibilityElement()
            .accessibilityLabel("Layers sheet")
            .accessibilityValue(detent.accessibilityValue)
            .accessibilityHint("Double-tap to resize")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { setDetent(detent.cycled) }
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: setDetent(SheetDetent(rawValue: detent.rawValue + 1) ?? .expanded)
                case .decrement: setDetent(SheetDetent(rawValue: detent.rawValue - 1) ?? .collapsed)
                @unknown default: break
                }
            }
    }

    private func dragGesture(layout: SheetLayout) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                if dragAxis == nil {
                    dragAxis = abs(value.translation.height) >= abs(value.translation.width) ? .vertical : .horizontal
                }
                guard dragAxis == .vertical else { return }
                dragTranslation = value.translation.height
            }
            .onEnded { value in
                defer { dragAxis = nil }
                guard dragAxis == .vertical else { return }
                let target = layout.snap(from: detent, translation: value.translation.height,
                                         velocity: value.velocity.height)
                withAnimation(animation) {
                    detent = target
                    dragTranslation = 0
                }
            }
    }

    private func setDetent(_ new: SheetDetent) {
        withAnimation(animation) { detent = new }
    }

    /// Home-indicator inset the sheet extends under. The proxy of a view that
    /// ignores the bottom safe area reports 0, so read it from the window;
    /// when the keyboard is up (container well short of the window's safe
    /// height) the sheet sits on the keyboard and needs no inset.
    private static func homeIndicatorInset(containerHeight: CGFloat) -> CGFloat {
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        guard let window else { return 0 }
        let insets = window.safeAreaInsets
        let fullHeight = window.bounds.height - insets.top
        return containerHeight < fullHeight - 100 ? 0 : insets.bottom
    }

    /// Follows the finger between the detents and resists beyond them.
    private func rubberBanded(_ proposed: CGFloat, layout: SheetLayout) -> CGFloat {
        if proposed < layout.collapsed {
            return layout.collapsed - (layout.collapsed - proposed) * 0.2
        }
        if proposed > layout.expanded {
            return layout.expanded + (proposed - layout.expanded) * 0.2
        }
        return proposed
    }
}

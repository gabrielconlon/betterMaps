import SwiftUI
import SwiftData

/// The pages of the first-run walkthrough, in order.
enum WelcomePage: Int, CaseIterable, Identifiable {
    case welcome
    case transit
    case gettingAround
    case done

    var id: Int { rawValue }

    var next: WelcomePage? { WelcomePage(rawValue: rawValue + 1) }
    var previous: WelcomePage? { WelcomePage(rawValue: rawValue - 1) }
    var isLast: Bool { next == nil }
}

/// The once-only welcome shown on first launch: what the app is, which
/// transit networks to draw, how the person likes to travel, then a summary.
/// One headline, two lines and one control per page (progressive
/// disclosure); Back/Next and page dots underneath. Every choice writes
/// straight to the same stores the Layers card and Settings use, so there
/// is nothing to "save" at the end.
///
/// `MapScreen` presents it full screen on iPhone/iPad and as a fixed-size
/// sheet on the Mac, where a close button (Escape) also finishes it.
struct WelcomeWalkthrough: View {
    @Bindable var transitSettings: TransitLayerSettings
    /// Called once when the person finishes or closes the walkthrough.
    let onFinish: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: WelcomePage = .welcome
    /// The one preferences row, fetched (or created) when the walkthrough
    /// opens so the Getting around page has something to bind to.
    @State private var prefsRow: DirectionsPreferences?

    #if targetEnvironment(macCatalyst)
    static let macSize = CGSize(width: 560, height: 700)
    #endif

    var body: some View {
        VStack(spacing: 0) {
            #if targetEnvironment(macCatalyst)
            closeRow
            #endif

            pageBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(page)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)))

            footer
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: page)
        .onAppear(perform: ensurePrefsRow)
        #if targetEnvironment(macCatalyst)
        .frame(width: Self.macSize.width, height: Self.macSize.height)
        .interactiveDismissDisabled()
        #endif
    }

    // MARK: - Pages

    @ViewBuilder
    private var pageBody: some View {
        switch page {
        case .welcome:
            WelcomeIntroPage()
                .welcomePage(.welcome)
        case .transit:
            WelcomeTransitPage(settings: transitSettings)
                .welcomePage(.transit)
        case .gettingAround:
            WelcomeGettingAroundPage(prefs: prefsRow?.snapshot ?? .default) { snapshot in
                guard let prefsRow else { return }
                prefsRow.apply(snapshot)
                try? modelContext.save()
            }
            .welcomePage(.gettingAround)
        case .done:
            WelcomeDonePage(lines: WelcomeSummary.lines(prefs: prefsRow?.snapshot ?? .default,
                                                        transitKinds: transitSettings.enabledKinds))
                .welcomePage(.done)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 16) {
            pageDots
            HStack(spacing: 12) {
                if let previous = page.previous {
                    Button {
                        page = previous
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .labelStyle(.titleOnly)
                            .frame(minWidth: 88, minHeight: 32)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("welcome.back")
                }

                if let next = page.next {
                    Button {
                        page = next
                    } label: {
                        Text("Next")
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("welcome.next")
                } else {
                    Button(action: onFinish) {
                        Text("Start exploring")
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("welcome.done")
                }
            }
        }
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(WelcomePage.allCases) { dot in
                Circle()
                    .fill(dot == page ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(page.rawValue + 1) of \(WelcomePage.allCases.count)")
    }

    #if targetEnvironment(macCatalyst)
    private var closeRow: some View {
        HStack {
            Spacer()
            Button(action: onFinish) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("welcome.close")
            .help("Close (Esc)")
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }
    #endif

    // MARK: - Data

    private func ensurePrefsRow() {
        guard prefsRow == nil else { return }
        guard let row = try? DirectionsPreferences.fetchOrCreate(in: modelContext) else { return }
        try? modelContext.save()
        prefsRow = row
    }
}

// MARK: - Page frame

private struct WelcomePageModifier: ViewModifier {
    let page: WelcomePage

    func body(content: Content) -> some View {
        ScrollView {
            content
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 8)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        // Kept off the safe-area edge so scrolled copy never runs under the
        // status bar (a scroll view touching that edge draws beneath it).
        .padding(.top, 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("welcome.page.\(page.rawValue)")
    }
}

extension View {
    /// Scrolls when the content is taller than the screen and names the page
    /// for accessibility (`welcome.page.<index>`).
    func welcomePage(_ page: WelcomePage) -> some View {
        modifier(WelcomePageModifier(page: page))
    }
}

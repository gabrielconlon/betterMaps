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
/// is nothing to "save" at the end (an edit the store refused is retried
/// once from "Start exploring").
///
/// Each page is a scroll view that owns the top safe area, so long copy
/// scrolls under the status bar like any iOS screen; the footer is a bottom
/// safe-area inset the pages scroll beneath.
///
/// `MapScreen` presents it full screen on iPhone/iPad and as a fixed-size
/// sheet on the Mac, where a close button (Escape) also finishes it.
struct WelcomeWalkthrough: View {
    let transitSettings: TransitLayerSettings
    /// Called once when the person finishes or closes the walkthrough.
    let onFinish: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: WelcomePage = .welcome
    /// What the Getting around controls show; the store's values once read,
    /// the person's edit from then on.
    @State private var prefsState = WelcomePreferencesState()
    /// The preferences row as last fetched. Only ever used through
    /// `DirectionsPreferences.liveRow`, which refetches once it is deleted.
    @State private var prefsRow: DirectionsPreferences?

    #if targetEnvironment(macCatalyst)
    static let macSize = CGSize(width: 560, height: 700)
    #endif

    private var background: Color { Color(.systemGroupedBackground) }

    var body: some View {
        ZStack {
            pageBody
                .id(page)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)))
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
                .background(background)
        }
        #if targetEnvironment(macCatalyst)
        .safeAreaInset(edge: .top, spacing: 0) {
            closeRow.background(background)
        }
        #endif
        .background(background.ignoresSafeArea())
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: page)
        .onAppear(perform: loadPrefs)
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)
            .merge(with: NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange))
            .receive(on: RunLoop.main)) { _ in
            refreshPrefs()
        }
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
            WelcomeGettingAroundPage(prefs: prefsState.prefs) { snapshot in
                prefsState.edited(snapshot)
                persistPrefs()
            }
            .welcomePage(.gettingAround)
        case .done:
            WelcomeDonePage(lines: WelcomeSummary.lines(prefs: prefsState.prefs,
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
                    Button(action: finish) {
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

    /// Reads (or creates) the row once. When the store refuses, the controls
    /// bind to the local defaults and `persistPrefs` tries the store again
    /// on each edit.
    private func loadPrefs() {
        guard prefsRow == nil else { return }
        guard let row = try? DirectionsPreferences.ensureRow(in: modelContext) else { return }
        prefsRow = row
        prefsState.loaded(row.snapshot)
    }

    /// Any save or remote change: the row is fetched again (it may have been
    /// replaced or merged) and its values shown unless an edit is waiting.
    private func refreshPrefs() {
        guard let row = try? DirectionsPreferences.fetchOrCreate(in: modelContext) else { return }
        if row !== prefsRow { prefsRow = row }
        prefsState.loaded(row.snapshot)
    }

    /// Writes the working copy to the live row. A failure keeps the edit
    /// (and `hasUnsavedEdit`) for the retry from "Start exploring".
    private func persistPrefs() {
        do {
            let row = try DirectionsPreferences.liveRow(prefsRow, in: modelContext)
            if row !== prefsRow { prefsRow = row }
            row.apply(prefsState.prefs)
            try modelContext.save()
            prefsState.saved()
        } catch {
            // Left unsaved on purpose; see `finish`.
        }
    }

    /// "Start exploring": one more go at an edit the store refused, then
    /// hand the map back either way.
    private func finish() {
        if prefsState.hasUnsavedEdit { persistPrefs() }
        onFinish()
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

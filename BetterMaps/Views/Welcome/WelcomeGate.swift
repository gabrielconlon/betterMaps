import Foundation

/// Decides whether the first-run welcome walkthrough shows at launch. Pure,
/// so the decision is unit-tested; `MapScreen` feeds it the real inputs.
///
/// - Completed once (`welcome.completed.v1`), it never shows again unless
///   Settings asks for it or `-ResetWelcome` (DEBUG) clears the flag.
/// - The unit-test host and every UI-test, perf and screenshot launch argument
///   suppress it, so existing automation never sees the walkthrough.
/// - `-UITestWelcome` forces it on (for its own UI test) and beats the other
///   arguments, but never the test host.
enum WelcomeGate {
    static let storageKey = "welcome.completed.v1"
    static let forceArgument = "-UITestWelcome"
    static let resetArgument = "-ResetWelcome"

    /// Launch arguments that mean "an automation drives this launch".
    static let suppressingArguments: Set<String> = [
        "-PerfSeed", "-UITestMapProbe", "-UITestFakeDirections",
        "-openPlaceDetail", "-openQuickAdd", "-openTrailEditor", "-openLayersPanel"
    ]

    static func shouldShow(completed: Bool, arguments: [String], isTestHost: Bool) -> Bool {
        if isTestHost { return false }
        if arguments.contains(forceArgument) { return true }
        if arguments.contains(where: suppressingArguments.contains) { return false }
        return !completed
    }

    /// True when this process only hosts the unit tests.
    static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// `shouldShow` against this process.
    static func shouldShowNow(completed: Bool) -> Bool {
        shouldShow(completed: completed, arguments: ProcessInfo.processInfo.arguments, isTestHost: isTestHost)
    }

    /// `-ResetWelcome` was passed (DEBUG only): the flag is cleared before
    /// the decision.
    static var resetRequested: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains(resetArgument)
        #else
        return false
        #endif
    }
}

/// The Done page's summary of what was chosen, as plain lines. Pure so the
/// wording is unit-tested.
enum WelcomeSummary {
    struct Line: Equatable, Identifiable {
        let title: String
        let value: String
        var id: String { title }
    }

    static func lines(prefs: DirectionsPreferencesSnapshot,
                      transitKinds: Set<TransitLayerKind>) -> [Line] {
        let kinds = TransitLayerKind.allCases.filter(transitKinds.contains).map(\.displayName)
        let modes = TransitLayerKind.allCases.map(TransitMode.init)
            .filter(prefs.enabledModes.contains)
            .map(\.displayName)
        return [
            Line(title: "On the map", value: kinds.isEmpty ? "No transit yet" : kinds.joined(separator: ", ")),
            Line(title: "Walking", value: prefs.walkToleranceLabel),
            Line(title: "Travel by", value: modes.isEmpty ? "No networks" : modes.joined(separator: ", ")),
            Line(title: "Cycling the whole way", value: prefs.allowBikeDirect ? "On" : "Off")
        ]
    }
}

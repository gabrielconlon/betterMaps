import Foundation

/// Decides whether the first-run welcome walkthrough shows at launch. Pure,
/// so the decision is unit-tested; `MapScreen` feeds it the real inputs.
///
/// - Completed once (`welcome.completed.v1`), it never shows again unless
///   Settings asks for it or `-ResetWelcome` (DEBUG) clears the flag.
/// - The unit-test host and every automation launch argument (`-UITest…`,
///   `-Perf…`, `-open…` screenshot screens, `-sheetMedium`) suppress it, so
///   existing and future automation never sees the walkthrough.
/// - `-UITestWelcome` forces it on (for its own UI test) and beats the other
///   arguments, but never the test host.
enum WelcomeGate {
    static let storageKey = "welcome.completed.v1"
    static let forceArgument = "-UITestWelcome"
    static let resetArgument = "-ResetWelcome"

    /// Launch-argument families that mean "an automation drives this launch":
    /// UI-test flags, the perf harness and the debug screen openers.
    static let suppressingPrefixes = ["-UITest", "-Perf", "-open"]
    /// Single arguments that mean the same but share no prefix.
    static let suppressingArguments: Set<String> = ["-sheetMedium"]

    /// True when `argument` marks an automation launch (`forceArgument` aside,
    /// which `shouldShow` checks first).
    static func suppresses(_ argument: String) -> Bool {
        suppressingArguments.contains(argument)
            || suppressingPrefixes.contains { argument.hasPrefix($0) }
    }

    static func shouldShow(completed: Bool, arguments: [String], isTestHost: Bool) -> Bool {
        if isTestHost { return false }
        if arguments.contains(forceArgument) { return true }
        if arguments.contains(where: suppresses) { return false }
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

/// The Getting around page's working copy of the directions preferences and
/// whether the store has caught up with it. Pure so the merge rules are
/// unit-tested: an edit the store has not taken yet is never overwritten by
/// a re-read, and a re-read wins whenever nothing is waiting.
struct WelcomePreferencesState: Equatable {
    private(set) var prefs: DirectionsPreferencesSnapshot = .default
    /// An edit is waiting to be written (the row could not be fetched, or a
    /// save failed). "Start exploring" retries it once.
    private(set) var hasUnsavedEdit = false

    /// The live row was (re)read.
    mutating func loaded(_ stored: DirectionsPreferencesSnapshot) {
        guard !hasUnsavedEdit else { return }
        prefs = stored
    }

    /// The person changed a control; the value shows at once, saved or not.
    mutating func edited(_ snapshot: DirectionsPreferencesSnapshot) {
        prefs = snapshot
        hasUnsavedEdit = true
    }

    /// The last edit reached the store.
    mutating func saved() {
        hasUnsavedEdit = false
    }
}

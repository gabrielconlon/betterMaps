import SwiftUI

struct ContentView: View {
    @AppStorage("gtfsSetupComplete") private var setupComplete = false

    var body: some View {
        if setupComplete {
            MapTabView()
        } else {
            GTFSSetupView(isComplete: $setupComplete)
        }
    }
}

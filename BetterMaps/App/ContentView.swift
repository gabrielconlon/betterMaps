import SwiftUI

struct ContentView: View {
    @AppStorage("gtfsSetupComplete") private var setupComplete = false

    var body: some View {
        Group {
            if setupComplete {
                MapTabView()
                    .onAppear {
                        // Boot-path log so we can tell from console output
                        // whether MapTabView is even being instantiated
                        // when the user reports a "white screen" hang.
                        print("[BetterMaps] ContentView → MapTabView (setupComplete=true)")
                    }
            } else {
                GTFSSetupView(isComplete: $setupComplete)
                    .onAppear {
                        print("[BetterMaps] ContentView → GTFSSetupView (setupComplete=false)")
                    }
            }
        }
    }
}

import SwiftUI

struct SettingsTabView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Routing") {
                    NavigationLink(destination: WeatherRulesView()) {
                        Label("Weather Rules", systemImage: "cloud.sun")
                    }
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

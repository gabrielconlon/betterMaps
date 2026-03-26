import SwiftUI

struct SettingsTabView: View {
    @AppStorage("yelpAPIKey") private var yelpAPIKey = ""
    @State private var editingKey = ""
    @State private var showKeyField = false

    var body: some View {
        NavigationStack {
            List {
                Section("Routing") {
                    NavigationLink(destination: WeatherRulesView()) {
                        Label("Weather Rules", systemImage: "cloud.sun")
                    }
                }

                Section("Place Details") {
                    HStack {
                        Label("Yelp Integration", systemImage: "star.bubble")
                        Spacer()
                        if YelpService.isConfigured {
                            Text("Connected")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Text("Not Set")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onTapGesture { showKeyField.toggle() }

                    if showKeyField {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Enter your Yelp Fusion API key for hours, photos, and reviews. Get a free key at yelp.com/developers")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            SecureField("Yelp API Key", text: $editingKey)
                                .textFieldStyle(.roundedBorder)
                            Button("Save Key") {
                                yelpAPIKey = editingKey
                                YelpService.apiKey = editingKey
                                showKeyField = false
                            }
                            .disabled(editingKey.isEmpty)
                            .buttonStyle(.borderedProminent)
                        }
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
            .onAppear {
                // Load saved key on launch
                if !yelpAPIKey.isEmpty {
                    YelpService.apiKey = yelpAPIKey
                }
                editingKey = yelpAPIKey
            }
        }
    }
}

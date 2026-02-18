import SwiftUI

struct SettingsView: View {
    @State private var apiKey: String
    @State private var baseURL: String
    @State private var modelName: String
    @State private var showSaved = false

    init() {
        let settings = AISettings.load()
        _apiKey = State(initialValue: settings.apiKey)
        _baseURL = State(initialValue: settings.baseURL)
        _modelName = State(initialValue: settings.modelName)
    }

    var body: some View {
        Form {
            Section {
                SecureField("API Key", text: $apiKey)

                TextField("Base URL (optional)", text: $baseURL)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .autocorrectionDisabled()

                TextField("Model", text: $modelName)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
            } header: {
                Text("AI API")
            } footer: {
                Text("Default: OpenAI API (api.openai.com). Supports any OpenAI-compatible API.")
            }

            Section {
                Button("Save Settings") {
                    let settings = AISettings(apiKey: apiKey, baseURL: baseURL, modelName: modelName)
                    settings.save()
                    showSaved = true
                }
            }

            Section("About") {
                LabeledContent("Version", value: "1.0.0")
                LabeledContent("App", value: "ConchTalk")
            }
        }
        .navigationTitle("Settings")
        .alert("Settings Saved", isPresented: $showSaved) {
            Button("OK") {}
        }
    }
}

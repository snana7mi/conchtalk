/// 文件说明：SettingsView，负责应用设置页面与配置项展示。
import SwiftUI

/// SettingsView：负责界面渲染与用户交互响应。
struct SettingsView: View {
    @State private var apiKey: String
    @State private var baseURL: String
    @State private var modelName: String
    @State private var maxContextTokensK: Int
    @State private var showSaved = false

    /// 初始化设置页面并加载当前配置。
    init() {
        let settings = AISettings.load()
        _apiKey = State(initialValue: settings.apiKey)
        _baseURL = State(initialValue: settings.baseURL)
        _modelName = State(initialValue: settings.modelName)
        _maxContextTokensK = State(initialValue: settings.maxContextTokensK)
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

                HStack {
                    Text("Max Context")
                    Spacer()
                    TextField("128", value: $maxContextTokensK, format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    Text("K tokens")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("AI API")
            } footer: {
                Text("Default: OpenAI API (api.openai.com). Supports any OpenAI-compatible API. Context window controls automatic conversation compression.")
            }

            Section {
                Button("Save Settings") {
                    let settings = AISettings(apiKey: apiKey, baseURL: baseURL, modelName: modelName, maxContextTokensK: max(maxContextTokensK, 1))
                    settings.save()
                    showSaved = true
                }
            }

            Section("About") {
                LabeledContent("Version", value: "1.0.0")
                LabeledContent("App", value: "ConchTalk")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        #if os(iOS)
        .simultaneousGesture(
            TapGesture().onEnded {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        )
        #endif
        .navigationTitle("Settings")
        .alert("Settings Saved", isPresented: $showSaved) {
            Button("OK") {}
        }
    }
}

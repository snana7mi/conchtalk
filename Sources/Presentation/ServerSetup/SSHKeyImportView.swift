import SwiftUI
import UniformTypeIdentifiers

struct SSHKeyImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var keyText = ""
    @State private var showFilePicker = false

    let onImport: (String) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Paste your SSH private key or import from file")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top)

                TextEditor(text: $keyText)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxHeight: .infinity)
                    .padding(8)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal)

                Button {
                    showFilePicker = true
                } label: {
                    Label("Import from File", systemImage: "doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal)
            }
            .padding(.bottom)
            .navigationTitle("Import SSH Key")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        onImport(keyText)
                        dismiss()
                    }
                    .disabled(keyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.data, .text]) { result in
                if case .success(let url) = result {
                    if url.startAccessingSecurityScopedResource() {
                        defer { url.stopAccessingSecurityScopedResource() }
                        if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
                            keyText = text
                        }
                    }
                }
            }
        }
    }
}

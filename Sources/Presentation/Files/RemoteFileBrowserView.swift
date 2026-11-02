/// 文件说明：RemoteFileBrowserView，应用内 SFTP 目录浏览器。
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// RemoteFileBrowserView：
/// 浏览远端目录，预览文本和图片，下载到临时文件，或把文件附加到当前聊天。
struct RemoteFileBrowserView: View {
    @State private var model: RemoteFileBrowserModel
    var onAttach: (String, Data) -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var selected: RemoteFileEntry?
    @State private var shareURL: URL?
    @State private var attachError: String?

    init(client: SSHClientProtocol, onAttach: @escaping (String, Data) -> String?) {
        _model = State(initialValue: RemoteFileBrowserModel(client: client))
        self.onAttach = onAttach
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading && model.entries.isEmpty {
                    ProgressView()
                } else if let errorMessage = model.errorMessage, model.entries.isEmpty, selected == nil {
                    ContentUnavailableView(
                        String(localized: "Could not open directory", bundle: LanguageSettings.currentBundle),
                        systemImage: "folder.badge.questionmark",
                        description: Text(errorMessage)
                    )
                } else {
                    List {
                        if model.path != "/" {
                            Button {
                                Task { await model.goUp() }
                            } label: {
                                Label("..", systemImage: "arrow.up")
                            }
                        }
                        ForEach(model.entries) { entry in
                            Button {
                                Task { await open(entry) }
                            } label: {
                                HStack {
                                    Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                                        .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                                    VStack(alignment: .leading) {
                                        Text(entry.name)
                                            .foregroundStyle(.primary)
                                        if let size = entry.size, !entry.isDirectory {
                                            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if entry.isDirectory {
                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(model.path)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: LanguageSettings.currentBundle)) {
                        dismiss()
                    }
                }
            }
            .sheet(item: $selected) { entry in
                RemoteFilePreviewSheet(
                    entry: entry,
                    preview: model.preview,
                    shareURL: shareURL,
                    onDownload: { Task { await download(entry) } },
                    onAttach: { Task { await attach(entry) } },
                    onClose: { selected = nil }
                )
            }
            .alert(
                String(localized: "File too large", bundle: LanguageSettings.currentBundle),
                isPresented: Binding(get: { attachError != nil }, set: { if !$0 { attachError = nil } })
            ) {
                Button(String(localized: "OK", bundle: LanguageSettings.currentBundle), role: .cancel) {}
            } message: {
                Text(attachError ?? "")
            }
        }
        .task { await model.loadInitial() }
    }

    private func open(_ entry: RemoteFileEntry) async {
        if entry.isDirectory {
            await model.open(entry)
            return
        }
        shareURL = nil
        selected = entry
        await model.loadPreview(for: entry)
    }

    private func download(_ entry: RemoteFileEntry) async {
        do {
            let data = try await model.readFile(entry)
            shareURL = try RemoteFileDownload.writeTemporary(fileName: entry.name, data: data)
        } catch RemoteFileTransferError.tooLarge(let bytes) {
            attachError = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func attach(_ entry: RemoteFileEntry) async {
        do {
            let data = try await model.readFile(entry)
            if let rejected = onAttach(entry.name, data) {
                attachError = rejected
            } else {
                dismiss()
            }
        } catch RemoteFileTransferError.tooLarge(let bytes) {
            attachError = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

/// RemoteFilePreviewSheet：单个远端文件的预览、下载和附加。
private struct RemoteFilePreviewSheet: View {
    let entry: RemoteFileEntry
    let preview: RemoteFilePreview?
    let shareURL: URL?
    let onDownload: () -> Void
    let onAttach: () -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    previewBody
                    HStack {
                        Button(String(localized: "Download", bundle: LanguageSettings.currentBundle), action: onDownload)
                            .buttonStyle(.bordered)
                        Button(String(localized: "Attach to chat", bundle: LanguageSettings.currentBundle), action: onAttach)
                            .buttonStyle(.borderedProminent)
                    }
                    if let shareURL {
                        ShareLink(item: shareURL) {
                            Label(String(localized: "Share", bundle: LanguageSettings.currentBundle), systemImage: "square.and.arrow.up")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle(entry.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: LanguageSettings.currentBundle), action: onClose)
                }
            }
        }
    }

    @ViewBuilder
    private var previewBody: some View {
        switch preview {
        case .text(let text):
            Text(text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        case .image(let data):
            imagePreview(data)
        case .tooLarge:
            Text(String(localized: "This file is too large to preview.", bundle: LanguageSettings.currentBundle))
                .foregroundStyle(.secondary)
        case .binary:
            Text(String(localized: "No preview for this file type.", bundle: LanguageSettings.currentBundle))
                .foregroundStyle(.secondary)
        case nil:
            ProgressView()
        }
    }

    @ViewBuilder
    private func imagePreview(_ data: Data) -> some View {
        #if canImport(UIKit)
        if let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        } else {
            Text(String(localized: "No preview for this file type.", bundle: LanguageSettings.currentBundle))
        }
        #else
        Text(String(localized: "No preview for this file type.", bundle: LanguageSettings.currentBundle))
        #endif
    }
}

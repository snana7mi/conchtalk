/// 文件说明：KnownHostsManagementView，列出已信任的主机密钥，可查看指纹并删除。
import SwiftUI

/// KnownHostsManagementViewModel：从共享的 KnownHostsStore 读取和删除记录。
@MainActor
@Observable
final class KnownHostsManagementViewModel {
    private let store: KnownHostsStore
    private(set) var records: [KnownHostRecord] = []

    init(store: KnownHostsStore) {
        self.store = store
    }

    func load() async {
        records = await store.list()
    }

    func delete(_ record: KnownHostRecord) async {
        await store.remove(host: record.host, port: record.port)
        await load()
    }
}

/// KnownHostsManagementView：主机密钥列表。点进去看完整指纹，滑动或详情页可删除。
struct KnownHostsManagementView: View {
    @State private var viewModel: KnownHostsManagementViewModel
    @State private var pendingDelete: KnownHostRecord?

    init(store: KnownHostsStore) {
        _viewModel = State(initialValue: KnownHostsManagementViewModel(store: store))
    }

    var body: some View {
        List {
            if viewModel.records.isEmpty {
                ContentUnavailableView(
                    String(localized: "No Host Keys", bundle: LanguageSettings.currentBundle),
                    systemImage: "lock.shield"
                )
            }
            ForEach(viewModel.records) { record in
                NavigationLink {
                    KnownHostDetailView(record: record, viewModel: viewModel)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(record.host):\(record.port)")
                            .font(.body)
                        Text(HostKeyFingerprint.openSSH(hex: record.fingerprint))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        pendingDelete = record
                    } label: {
                        Label(String(localized: "Delete", bundle: LanguageSettings.currentBundle), systemImage: "trash")
                    }
                }
            }
            Section {
                Text(String(
                    localized: "Known host keys are stored on this device. Deleting one makes the next connection ask you to verify the fingerprint again.",
                    bundle: LanguageSettings.currentBundle
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(String(localized: "Host Keys", bundle: LanguageSettings.currentBundle))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await viewModel.load() }
        .alert(
            String(localized: "Delete Host Key", bundle: LanguageSettings.currentBundle),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { record in
            Button(String(localized: "Cancel", bundle: LanguageSettings.currentBundle), role: .cancel) {
                pendingDelete = nil
            }
            Button(String(localized: "Delete", bundle: LanguageSettings.currentBundle), role: .destructive) {
                let target = record
                pendingDelete = nil
                Task { await viewModel.delete(target) }
            }
        } message: { record in
            let endpoint = "\(record.host):\(record.port)"
            Text(String(
                localized: "Remove the trusted key for \(endpoint)? The next connection will ask you to verify the fingerprint again.",
                bundle: LanguageSettings.currentBundle
            ))
        }
    }
}

/// KnownHostDetailView：展示一条主机密钥的 SHA256 指纹、十六进制摘要和添加时间。
struct KnownHostDetailView: View {
    let record: KnownHostRecord
    let viewModel: KnownHostsManagementViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showCopied = false
    @State private var showDelete = false

    var body: some View {
        Form {
            Section(String(localized: "Host", bundle: LanguageSettings.currentBundle)) {
                LabeledContent(String(localized: "Host", bundle: LanguageSettings.currentBundle), value: record.host)
                LabeledContent(String(localized: "Port", bundle: LanguageSettings.currentBundle), value: "\(record.port)")
                LabeledContent(
                    String(localized: "Added", bundle: LanguageSettings.currentBundle),
                    value: record.addedAt.formatted(date: .abbreviated, time: .shortened)
                )
            }
            Section {
                Text(HostKeyFingerprint.openSSH(hex: record.fingerprint))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Button(showCopied
                    ? String(localized: "Copied!", bundle: LanguageSettings.currentBundle)
                    : String(localized: "Copy", bundle: LanguageSettings.currentBundle)
                ) {
                    copyFingerprint()
                }
            } header: {
                Text(String(localized: "SHA256 Fingerprint", bundle: LanguageSettings.currentBundle))
            }
            Section(String(localized: "Hex Digest", bundle: LanguageSettings.currentBundle)) {
                Text(record.fingerprint)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            Section {
                Button(String(localized: "Delete Host Key", bundle: LanguageSettings.currentBundle), role: .destructive) {
                    showDelete = true
                }
            }
        }
        .navigationTitle("\(record.host):\(record.port)")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert(String(localized: "Delete Host Key", bundle: LanguageSettings.currentBundle), isPresented: $showDelete) {
            Button(String(localized: "Cancel", bundle: LanguageSettings.currentBundle), role: .cancel) {}
            Button(String(localized: "Delete", bundle: LanguageSettings.currentBundle), role: .destructive) {
                Task {
                    await viewModel.delete(record)
                    dismiss()
                }
            }
        } message: {
            let endpoint = "\(record.host):\(record.port)"
            Text(String(
                localized: "Remove the trusted key for \(endpoint)? The next connection will ask you to verify the fingerprint again.",
                bundle: LanguageSettings.currentBundle
            ))
        }
    }

    private func copyFingerprint() {
        #if os(iOS)
        UIPasteboard.general.string = HostKeyFingerprint.openSSH(hex: record.fingerprint)
        #endif
        showCopied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            showCopied = false
        }
    }
}

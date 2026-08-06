/// 文件说明：DirectoryBrowserSheet，目录浏览器 Sheet，用于在连接 coding agent 前选择工作目录。
import SwiftUI

/// DirectoryBrowserSheet：
/// 在 coding agent 接入前展示的目录浏览 Sheet。
/// 显示当前目录下的文件夹列表，支持点击进入子目录、返回上级、选择当前目录、自定义路径。
struct DirectoryBrowserSheet: View {
    @Bindable var coordinator: AgentPickerCoordinator

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 当前路径显示
                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.secondary)
                    Text(coordinator.browserPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.08))

                // 目录列表
                if coordinator.browserLoading {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else {
                    List {
                        // 返回上级
                        if coordinator.browserPath != "/" {
                            Button {
                                coordinator.browseParentDirectory()
                            } label: {
                                HStack {
                                    Image(systemName: "arrow.up.doc")
                                        .foregroundStyle(.blue)
                                    Text("..")
                                        .foregroundStyle(.primary)
                                }
                            }
                        }

                        if coordinator.browserEntries.isEmpty {
                            // 空目录提示（在 List 内，保留返回上级按钮）
                            HStack {
                                Spacer()
                                VStack(spacing: 8) {
                                    Image(systemName: "folder.badge.questionmark")
                                        .font(.largeTitle)
                                        .foregroundStyle(.secondary)
                                    Text(String(localized: "No subdirectories", bundle: LanguageSettings.currentBundle))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .listRowSeparator(.hidden)
                        } else {
                            // 目录列表
                            ForEach(coordinator.browserEntries, id: \.self) { dirName in
                                Button {
                                    coordinator.browseIntoDirectory(dirName)
                                } label: {
                                    HStack {
                                        Image(systemName: "folder.fill")
                                            .foregroundStyle(.blue)
                                        Text(dirName)
                                            .foregroundStyle(.primary)
                                        Spacer()
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

                Divider()

                // 底部操作区
                VStack(spacing: 12) {
                    Button {
                        coordinator.confirmDirectorySelection()
                    } label: {
                        Text(String(localized: "Open in this directory", bundle: LanguageSettings.currentBundle))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        coordinator.requestCustomPath()
                    } label: {
                        Text(String(localized: "Custom path...", bundle: LanguageSettings.currentBundle))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle(String(localized: "Select Working Directory", bundle: LanguageSettings.currentBundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: LanguageSettings.currentBundle)) {
                        coordinator.cancelDirectoryBrowser()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

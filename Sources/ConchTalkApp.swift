//
//  ConchTalkApp.swift
//  ConchTalk
//
//  Created by cheung on 2026/02/16.
//

/// 文件说明：ConchTalkApp，应用入口，负责初始化依赖并组织主界面导航。
import SwiftUI
import SwiftData

/// ConchTalkApp：应用入口与全局导航的组装点。
@main
struct ConchTalkApp: App {
    @State private var container = DependencyContainer()
    @State private var selectedServer: Server?
    @State private var selectedConversation: Conversation?
    @State private var selectedConversationID: UUID?

    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("Servers", systemImage: "server.rack") {
                    NavigationStack {
                        ServerListView(
                            viewModel: container.makeServerListViewModel(),
                            onSelectServer: { server in
                                selectedConversation = nil
                                selectedConversationID = nil
                                selectedServer = server
                            },
                            onSelectConversation: { result in
                                Task {
                                    let servers = try? await container.store.fetchServers()
                                    if let server = servers?.first(where: { $0.id == result.serverID }) {
                                        let conversation = Conversation(
                                            id: result.id,
                                            serverID: result.serverID,
                                            title: result.conversationTitle
                                        )
                                        selectedConversationID = result.id
                                        selectedConversation = conversation
                                        selectedServer = server
                                    }
                                }
                            }
                        )
                        .navigationDestination(item: $selectedServer) { server in
                            ConversationListView(
                                server: server,
                                store: container.store,
                                selectedConversation: $selectedConversation
                            )
                            .navigationDestination(item: $selectedConversation) { conversation in
                                ChatView(viewModel: container.makeChatViewModel(for: server, conversationID: conversation.id))
                            }
                        }
                    }
                }
                Tab("Settings", systemImage: "gear") {
                    NavigationStack {
                        SettingsView()
                    }
                }
            }
        }
        .modelContainer(container.modelContainer)
    }
}

import Foundation

final class AIProxyService: AIServiceProtocol, @unchecked Sendable {
    private let session: URLSession
    private let keychainService: KeychainServiceProtocol

    init(keychainService: KeychainServiceProtocol) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        self.session = URLSession(configuration: config)
        self.keychainService = keychainService
    }

    // MARK: - AIServiceProtocol

    func sendMessage(_ message: String, conversationHistory: [Message], serverContext: String) async throws -> AIResponse {
        var messages = buildOpenAIMessages(from: conversationHistory, serverContext: serverContext)
        messages.append(["role": "user", "content": message])
        return try await callOpenAI(messages: messages)
    }

    func sendCommandResult(_ result: String, forCommand command: SSHCommand, conversationHistory: [Message], serverContext: String) async throws -> AIResponse {
        let messages = buildOpenAIMessages(from: conversationHistory, serverContext: serverContext)
        return try await callOpenAI(messages: messages)
    }

    // MARK: - OpenAI API

    private func callOpenAI(messages: [[String: Any]]) async throws -> AIResponse {
        let settings = AISettings.load()
        guard !settings.apiKey.isEmpty else {
            throw AIServiceError.apiKeyMissing
        }

        let baseURL = settings.baseURL.isEmpty ? "https://api.openai.com/v1" : settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = URL(string: "\(baseURL)/chat/completions")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": settings.modelName,
            "messages": messages,
            "tools": [Self.toolDefinition],
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AIServiceError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first,
              let message = choice["message"] as? [String: Any] else {
            throw AIServiceError.invalidResponse
        }

        // Check for tool calls
        if let toolCalls = message["tool_calls"] as? [[String: Any]],
           let toolCall = toolCalls.first,
           let function = toolCall["function"] as? [String: Any],
           let name = function["name"] as? String,
           name == "execute_ssh_command",
           let arguments = function["arguments"] as? String,
           let argData = arguments.data(using: .utf8) {
            let cmd = try JSONDecoder().decode(SSHCommand.self, from: argData)
            return .command(cmd)
        }

        // Text response
        let content = message["content"] as? String ?? ""
        return .text(content)
    }

    // MARK: - Message Conversion

    private func buildOpenAIMessages(from history: [Message], serverContext: String) -> [[String: Any]] {
        var openAIMessages: [[String: Any]] = []

        // System prompt
        openAIMessages.append([
            "role": "system",
            "content": Self.systemPrompt(serverContext: serverContext),
        ])

        var toolCallCounter = 0
        for msg in history where !msg.isLoading {
            switch msg.role {
            case .user:
                openAIMessages.append(["role": "user", "content": msg.content])
            case .assistant:
                openAIMessages.append(["role": "assistant", "content": msg.content])
            case .command:
                if let cmd = msg.command {
                    toolCallCounter += 1
                    let toolCallID = "call_\(toolCallCounter)"
                    let argsJSON = try? JSONEncoder().encode(cmd)
                    let argsString = argsJSON.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

                    // Assistant message with tool call
                    openAIMessages.append([
                        "role": "assistant",
                        "content": NSNull(),
                        "tool_calls": [
                            [
                                "id": toolCallID,
                                "type": "function",
                                "function": [
                                    "name": "execute_ssh_command",
                                    "arguments": argsString,
                                ] as [String: Any],
                            ] as [String: Any],
                        ],
                    ])

                    // Tool response
                    openAIMessages.append([
                        "role": "tool",
                        "tool_call_id": toolCallID,
                        "content": msg.commandOutput ?? "",
                    ])
                }
            case .system:
                openAIMessages.append(["role": "user", "content": "[System: \(msg.content)]"])
            }
        }

        return openAIMessages
    }

    // MARK: - System Prompt

    private static func systemPrompt(serverContext: String) -> String {
        """
        You are ConchTalk (海螺对话), an intelligent SSH assistant. You help users manage remote servers through natural language conversations.

        ## Your Role
        - Translate user requests into SSH commands
        - Execute commands step by step, analyzing results before proceeding
        - Provide clear explanations in the user's language (Chinese or English, match the user)
        - When a task requires multiple steps, execute them one at a time

        ## Server Context
        \(serverContext)

        ## Rules
        1. Use the execute_ssh_command tool to run commands on the server
        2. For read-only operations (ls, cat, ps, df, etc.), set is_destructive to false
        3. For write/modify operations (rm, mv, apt install, service restart, etc.), set is_destructive to true
        4. Never execute obviously dangerous commands like "rm -rf /", "mkfs", "dd if=/dev/zero" etc.
        5. Always explain what each command does
        6. After executing a command, analyze the output and decide the next step
        7. When the task is complete, provide a summary in natural language (not a tool call)
        8. If a command fails, explain the error and suggest alternatives
        9. Keep explanations concise but informative

        ## Response Format
        - When you need to execute a command: use the execute_ssh_command tool
        - When you want to communicate with the user: respond with plain text
        - Always match the user's language (if they write in Chinese, respond in Chinese)
        """
    }

    // MARK: - Tool Definition

    private static let toolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "execute_ssh_command",
            "description": "Execute an SSH command on the remote server. Use this to run commands that help accomplish the user's task.",
            "parameters": [
                "type": "object",
                "properties": [
                    "command": [
                        "type": "string",
                        "description": "The shell command to execute on the remote server",
                    ] as [String: String],
                    "explanation": [
                        "type": "string",
                        "description": "A brief explanation of what this command does, in the user's language",
                    ] as [String: String],
                    "is_destructive": [
                        "type": "boolean",
                        "description": "Whether this command modifies server state (write/delete/restart operations). Read-only commands like ls, cat, ps should be false.",
                    ] as [String: String],
                ] as [String: [String: String]],
                "required": ["command", "explanation", "is_destructive"],
            ] as [String: Any],
        ] as [String: Any],
    ]
}

// MARK: - AI Settings (stored in UserDefaults + Keychain)

struct AISettings {
    var apiKey: String
    var baseURL: String
    var modelName: String

    static func load() -> AISettings {
        let defaults = UserDefaults.standard
        return AISettings(
            apiKey: defaults.string(forKey: "aiAPIKey") ?? "",
            baseURL: defaults.string(forKey: "aiBaseURL") ?? "",
            modelName: defaults.string(forKey: "aiModelName") ?? "gpt-4o"
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(apiKey, forKey: "aiAPIKey")
        defaults.set(baseURL, forKey: "aiBaseURL")
        defaults.set(modelName, forKey: "aiModelName")
    }
}

// MARK: - Errors

enum AIServiceError: LocalizedError {
    case apiKeyMissing
    case invalidResponse
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .apiKeyMissing: return "API Key not configured. Go to Settings to add your API key."
        case .invalidResponse: return "Invalid response from AI service"
        case .apiError(let code, let msg): return "AI API error (\(code)): \(msg)"
        }
    }
}

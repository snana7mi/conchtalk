/// 文件说明：PCCTranscriptMapper，把 OpenAI 协议消息与 JSON Schema 转为 Foundation Models 的 Transcript / GenerationSchema。
import Foundation
import FoundationModels

/// PCCTranscriptMapper：
/// 复用 `MessageBuilder` 产出的 OpenAI 格式消息（system / user / assistant / tool），
/// 映射为 `Transcript.Entry`，使 PCC 与自有端点共享同一套历史语义。
@available(iOS 27.0, macOS 27.0, *)
nonisolated enum PCCTranscriptMapper {

    /// 构建以 instructions 开头的完整 transcript 条目。
    static func transcriptEntries(
        instructions: String,
        toolDefinitions: [Transcript.ToolDefinition],
        messages: [[String: Any]]
    ) -> [Transcript.Entry] {
        var entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: instructions))],
                toolDefinitions: toolDefinitions
            )),
        ]
        entries.append(contentsOf: historyEntries(from: messages))
        return entries
    }

    /// 将 OpenAI 格式消息映射为历史条目。system 消息并入 instructions，这里跳过。
    static func historyEntries(from messages: [[String: Any]]) -> [Transcript.Entry] {
        var entries: [Transcript.Entry] = []
        var toolNamesByCallID: [String: String] = [:]

        for message in messages {
            let role = message["role"] as? String ?? ""
            let content = message["content"] as? String ?? ""
            switch role {
            case "user":
                entries.append(.prompt(Transcript.Prompt(segments: [textSegment(content)])))
            case "assistant":
                if !content.isEmpty {
                    entries.append(.response(Transcript.Response(assetIDs: [], segments: [textSegment(content)])))
                }
                let rawCalls = message["tool_calls"] as? [[String: Any]] ?? []
                let calls: [Transcript.ToolCall] = rawCalls.compactMap { raw in
                    guard let id = raw["id"] as? String,
                          let function = raw["function"] as? [String: Any],
                          let name = function["name"] as? String else { return nil }
                    let argumentsJSON = function["arguments"] as? String ?? "{}"
                    guard let arguments = generatedContent(fromJSON: argumentsJSON) else { return nil }
                    toolNamesByCallID[id] = name
                    return Transcript.ToolCall(id: id, toolName: name, arguments: arguments)
                }
                if !calls.isEmpty {
                    entries.append(.toolCalls(Transcript.ToolCalls(calls)))
                }
            case "tool":
                let callID = message["tool_call_id"] as? String ?? UUID().uuidString
                entries.append(.toolOutput(Transcript.ToolOutput(
                    id: callID,
                    toolName: toolNamesByCallID[callID] ?? "tool",
                    segments: [textSegment(content)]
                )))
            default:
                continue
            }
        }
        return entries
    }

    /// 把模型发起的工具调用转换为应用内 `ToolCall`，交给现有审批 / 执行流程。
    static func toolCalls(from transcriptCalls: [Transcript.ToolCall], responseID: String) -> [ToolCall] {
        transcriptCalls.map { call in
            let json = call.arguments.jsonString
            let data = Data(json.utf8)
            let arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let explanation = (arguments?["explanation"] as? String) ?? call.toolName
            var toolCall = ToolCall(id: call.id, toolName: call.toolName, argumentsJSON: data, explanation: explanation)
            toolCall.responseID = responseID
            return toolCall
        }
    }

    /// 取 transcript 中最后一组工具调用（会话因拦截工具执行而中断时即为本轮调用）。
    static func lastToolCalls(in entries: some Collection<Transcript.Entry>) -> [Transcript.ToolCall] {
        for entry in entries.reversed() {
            if case .toolCalls(let calls) = entry { return Array(calls) }
        }
        return []
    }

    /// 汇总条目中的推理文本，用于流式 diff。
    static func reasoningText(in entries: some Collection<Transcript.Entry>) -> String {
        entries.compactMap { entry -> String? in
            guard case .reasoning(let reasoning) = entry else { return nil }
            return reasoning.segments.compactMap { segment -> String? in
                if case .text(let text) = segment { return text.content }
                return nil
            }.joined()
        }.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func textSegment(_ content: String) -> Transcript.Segment {
        .text(Transcript.TextSegment(content: content))
    }

    private static func generatedContent(fromJSON json: String) -> GeneratedContent? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? GeneratedContent(json: trimmed.isEmpty ? "{}" : trimmed))
            ?? (try? GeneratedContent(json: "{}"))
    }
}

/// PCCSchemaConverter：把工具的 JSON Schema（OpenAI `parameters`）转为 `GenerationSchema`。
@available(iOS 27.0, macOS 27.0, *)
nonisolated enum PCCSchemaConverter {

    static func generationSchema(name: String, jsonSchema: [String: Any]) throws -> GenerationSchema {
        try GenerationSchema(root: dynamicSchema(name: name, json: jsonSchema), dependencies: [])
    }

    /// 递归转换。对象属性按「必填优先、再按名称」排序，保证结果稳定。
    static func dynamicSchema(name: String, json: [String: Any]) -> DynamicGenerationSchema {
        let description = json["description"] as? String
        if let choices = json["enum"] as? [String], !choices.isEmpty {
            return DynamicGenerationSchema(name: name, description: description, anyOf: choices)
        }
        switch primaryType(of: json) {
        case "object":
            let properties = json["properties"] as? [String: Any] ?? [:]
            let required = Set(json["required"] as? [String] ?? [])
            let ordered = properties.keys.sorted { lhs, rhs in
                let l = required.contains(lhs), r = required.contains(rhs)
                return l == r ? lhs < rhs : l
            }
            return DynamicGenerationSchema(
                name: name,
                description: description,
                properties: ordered.map { key in
                    let sub = properties[key] as? [String: Any] ?? [:]
                    return DynamicGenerationSchema.Property(
                        name: key,
                        description: sub["description"] as? String,
                        schema: dynamicSchema(name: "\(name)_\(key)", json: sub),
                        isOptional: !required.contains(key)
                    )
                }
            )
        case "array":
            let items = json["items"] as? [String: Any] ?? ["type": "string"]
            return DynamicGenerationSchema(arrayOf: dynamicSchema(name: "\(name)_item", json: items))
        case "integer":
            return DynamicGenerationSchema(type: Int.self)
        case "number":
            return DynamicGenerationSchema(type: Double.self)
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        default:
            return DynamicGenerationSchema(type: String.self)
        }
    }

    /// `type` 可能是字符串或数组（如 `["string", "null"]`），取第一个非 null 类型。
    static func primaryType(of json: [String: Any]) -> String {
        if let type = json["type"] as? String { return type }
        if let types = json["type"] as? [String] { return types.first { $0 != "null" } ?? "string" }
        return json["properties"] != nil ? "object" : "string"
    }
}

/// PCCToolInterception：工具代理被模型调用时抛出，用于中断会话并把调用交回应用执行。
nonisolated struct PCCToolInterception: Error, Sendable {
    let toolName: String
}

/// PCCToolProxy：
/// 只向模型声明工具，不在 Foundation Models 内部执行。模型发起调用时抛出 `PCCToolInterception`，
/// 由 `PCCAIService` 转成 `StreamingDelta.toolCall`，复用现有 SSH 审批与执行流程。
@available(iOS 27.0, macOS 27.0, *)
nonisolated struct PCCToolProxy: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema

    var includesSchemaInInstructions: Bool { true }

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        throw PCCToolInterception(toolName: name)
    }

    /// 由 OpenAI 格式工具定义批量创建代理；无法转换的 schema 会被跳过并记录日志。
    static func proxies(fromOpenAIDefinitions definitions: [[String: Any]]) -> [PCCToolProxy] {
        definitions.compactMap { definition in
            guard let function = definition["function"] as? [String: Any],
                  let name = function["name"] as? String else { return nil }
            let parameters = function["parameters"] as? [String: Any] ?? ["type": "object", "properties": [:]]
            do {
                return PCCToolProxy(
                    name: name,
                    description: function["description"] as? String ?? "",
                    parameters: try PCCSchemaConverter.generationSchema(name: "\(name)_arguments", jsonSchema: parameters)
                )
            } catch {
                print("[PCC] Skipping tool \(name): schema conversion failed: \(error)")
                return nil
            }
        }
    }
}

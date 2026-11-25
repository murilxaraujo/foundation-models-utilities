public import Foundation
public import FoundationModels
public import MCP

/// One MCP tool call presented to the host for authorization.
///
/// The arguments are the decoded JSON object the model supplied. Nothing in
/// this value grants authority: the host decides whether the call may proceed.
public struct MCPToolCall: Sendable {
  public let serverName: String
  public let toolName: String
  public let arguments: [String: MCP.Value]

  public init(serverName: String, toolName: String, arguments: [String: MCP.Value]) {
    self.serverName = serverName
    self.toolName = toolName
    self.arguments = arguments
  }
}

/// A host gate consulted immediately before an MCP tool call is sent.
///
/// Throwing denies the call and no request reaches the MCP server.
public typealias MCPToolAuthorizer = @Sendable (MCPToolCall) async throws -> Void

/// Discovers a connected MCP client's tools and returns them in the provider-neutral
/// ``ToolGroup`` abstraction.
public extension MCP.Client {
  /// Discovers this client's remote tools and packages them as one tool group.
  ///
  /// The returned group is a snapshot. Call this method again after the server's
  /// tool list changes. `authorizeCall`, when supplied, runs on every tool
  /// invocation before the request is sent; a thrown error denies that call.
  func foundationModelToolGroup(
    named name: String,
    description: String = "Tools provided by a connected Model Context Protocol server.",
    authorizeCall: MCPToolAuthorizer? = nil
  ) async throws -> ToolGroup {
    let tools = try await discoverMCPTools(
      from: self,
      groupName: name,
      authorizeCall: authorizeCall
    )
    return ToolGroup(
      name: name,
      description: description,
      tools: tools
    )
  }
}

private func discoverMCPTools(
  from client: MCP.Client,
  groupName: String,
  authorizeCall: MCPToolAuthorizer?
) async throws -> [MCPToolAdapter] {
  var tools: [MCP.Tool] = []
  var cursor: String?
  var seenCursors = Set<String>()

  repeat {
    let page = try await client.listTools(cursor: cursor)
    tools.append(contentsOf: page.tools)
    cursor = page.nextCursor

    if let cursor, !seenCursors.insert(cursor).inserted {
      throw MCPToolsError.repeatedPaginationCursor(cursor)
    }
  } while cursor != nil

  return try tools.map {
    try MCPToolAdapter(client: client, groupName: groupName, tool: $0, authorizeCall: authorizeCall)
  }
}

/// A single remote MCP tool represented as a Foundation Models `Tool`.
///
/// Host policy is checked on every invocation, after arguments are decoded and
/// before the request is sent. A denial never reaches the remote server.
public struct MCPToolAdapter: FoundationModels.Tool {
  public typealias Arguments = GeneratedContent
  public typealias Output = FoundationModels.Prompt

  public let name: String
  public let description: String
  public let parameters: GenerationSchema

  /// The name used when calling the MCP server. `name` is namespaced for the
  /// Foundation Models session so tools from separate groups do not collide.
  public let remoteName: String

  private let client: MCP.Client
  private let groupName: String
  private let authorizeCall: MCPToolAuthorizer?

  fileprivate init(
    client: MCP.Client,
    groupName: String,
    tool: MCP.Tool,
    authorizeCall: MCPToolAuthorizer?
  ) throws {
    self.client = client
    self.groupName = groupName
    self.authorizeCall = authorizeCall
    self.remoteName = tool.name
    self.name = Self.namespacedName(groupName: groupName, toolName: tool.name)
    self.description = tool.description ?? "MCP tool \(tool.name) from \(groupName)."
    self.parameters = try Self.generationSchema(from: tool.inputSchema)
  }

  public func call(arguments: GeneratedContent) async throws -> FoundationModels.Prompt {
    let data = Data(arguments.jsonString.utf8)
    let value = try JSONDecoder().decode(MCP.Value.self, from: data)
    guard case .object(let properties) = value else {
      throw MCPToolsError.expectedObjectArguments(remoteName)
    }
    if let authorizeCall {
      try await authorizeCall(
        MCPToolCall(serverName: groupName, toolName: remoteName, arguments: properties)
      )
    }

    let request = MCP.CallTool.request(.init(name: remoteName, arguments: properties))
    let requestContext = try await client.send(request)
    let result = try await requestContext.value
    let renderedContent = result.content.map(Self.render).filter { !$0.isEmpty }
    let prefix = result.isError == true ? "The MCP tool reported an error.\n" : ""
    let text: String
    if !renderedContent.isEmpty {
      text = renderedContent.joined(separator: "\n\n")
    } else if let structuredContent = result.structuredContent {
      let data = try JSONEncoder().encode(structuredContent)
      text = String(decoding: data, as: UTF8.self)
    } else {
      text = "The MCP tool returned no text content."
    }
    return FoundationModels.Prompt(prefix + text)
  }

  private static func generationSchema(from inputSchema: MCP.Value) throws -> GenerationSchema {
    let root = try dynamicSchema(from: inputSchema, fallbackName: "Arguments")
    return try GenerationSchema(root: root, dependencies: [])
  }

  private static func dynamicSchema(
    from value: MCP.Value,
    fallbackName: String,
    description: String? = nil
  ) throws -> DynamicGenerationSchema {
    guard let schema = value.objectValue else {
      return DynamicGenerationSchema(type: GeneratedContent.self)
    }

    let schemaName =
      (schema["title"]?.stringValue).flatMap { $0.isEmpty ? nil : $0 }
      ?? fallbackName
    let schemaDescription = schema["description"]?.stringValue ?? description

    if let choices = schema["enum"]?.arrayValue {
      let strings = choices.compactMap(\.stringValue)
      if strings.count == choices.count, !strings.isEmpty {
        return DynamicGenerationSchema(
          name: schemaName,
          description: schemaDescription,
          anyOf: strings
        )
      }
    }

    if let choices = (schema["anyOf"] ?? schema["oneOf"])?.arrayValue, !choices.isEmpty {
      return DynamicGenerationSchema(
        name: schemaName,
        description: schemaDescription,
        anyOf: try choices.enumerated().map { index, choice in
          try dynamicSchema(from: choice, fallbackName: "\(schemaName)Choice\(index)")
        }
      )
    }

    switch schema["type"]?.stringValue {
    case "string":
      return DynamicGenerationSchema(type: String.self)
    case "integer":
      return DynamicGenerationSchema(type: Int.self)
    case "number":
      return DynamicGenerationSchema(type: Double.self)
    case "boolean":
      return DynamicGenerationSchema(type: Bool.self)
    case "array":
      let itemSchema =
        try schema["items"].map {
          try dynamicSchema(from: $0, fallbackName: "\(schemaName)Item")
        } ?? DynamicGenerationSchema(type: GeneratedContent.self)
      return DynamicGenerationSchema(arrayOf: itemSchema)
    case "object":
      // DynamicGenerationSchema models fixed object properties. For
      // dictionary-like JSON Schema, use GeneratedContent so arbitrary
      // keys and values remain representable.
      if let additionalProperties = schema["additionalProperties"] {
        if case .bool(false) = additionalProperties {
          // A false schema only disallows undeclared keys, which the
          // fixed-property representation already enforces.
        } else {
          return DynamicGenerationSchema(type: GeneratedContent.self)
        }
      }

      let properties = schema["properties"]?.objectValue ?? [:]
      let required = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
      let dynamicProperties = try properties.keys.sorted().map { key in
        DynamicGenerationSchema.Property(
          name: key,
          description: properties[key]?.objectValue?["description"]?.stringValue,
          schema: try dynamicSchema(
            from: properties[key] ?? .object([:]),
            fallbackName: key
          ),
          isOptional: !required.contains(key)
        )
      }
      return DynamicGenerationSchema(
        name: schemaName,
        description: schemaDescription,
        properties: dynamicProperties
      )
    default:
      // Keep unknown/extended JSON Schema values callable rather than
      // rejecting the whole MCP server during discovery.
      return DynamicGenerationSchema(type: GeneratedContent.self)
    }
  }

  private static func namespacedName(groupName: String, toolName: String) -> String {
    let rawName = "mcp_\(groupName)_\(toolName)"
    let sanitized = rawName.map { character in
      character.isLetter || character.isNumber || character == "_" ? character : "_"
    }
    return String(sanitized)
  }

  private static func render(_ content: MCP.Tool.Content) -> String {
    switch content {
    case .text(let text, _, _):
      return text
    case .image(_, let mimeType, _, _):
      return "[Image result omitted (\(mimeType)).]"
    case .audio(_, let mimeType, _, _):
      return "[Audio result omitted (\(mimeType)).]"
    case .resource(let resource, _, _):
      if let text = resource.text {
        return text
      }
      return "[Binary resource omitted: \(resource.uri).]"
    case .resourceLink(let uri, let name, _, let description, let mimeType, _):
      return
        "Resource link: \(name) (\(uri))\(description.map { ": \($0)" } ?? "")\(mimeType.map { " [\($0)]" } ?? "")"
    }
  }
}

public enum MCPToolsError: Error, LocalizedError {
  case expectedObjectArguments(String)
  case repeatedPaginationCursor(String)

  public var errorDescription: String? {
    switch self {
    case .expectedObjectArguments(let name):
      "Foundation Models supplied non-object arguments for MCP tool '\(name)'."
    case .repeatedPaginationCursor(let cursor):
      "The MCP server repeated the tools-list pagination cursor '\(cursor)'."
    }
  }
}

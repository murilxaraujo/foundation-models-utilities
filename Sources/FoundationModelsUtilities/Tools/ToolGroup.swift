//===----------------------------------------------------------------------===//
//
// This source file is part of the Foundation Models open source project.
//
// Copyright © 2024-2027 Apple Inc. and the Foundation Models project authors.
//
// Licensed under the Apache License v2.0
//
// See LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

public import FoundationModels

/// A named, composable collection of Foundation Models tools.
///
/// `ToolGroup` is independent of any tool provider. Add any `FoundationModels.Tool`
/// implementation, including locally implemented tools and tools adapted from a
/// remote service. Groups can also be nested to compose reusable toolsets:
///
/// ```swift
/// let localTools = ToolGroup(name: "Workspace") {
///     ReadFileTool()
///     SearchFilesTool()
/// }
/// let tools = ToolGroup(name: "Assistant") {
///     localTools
///     CalendarTool()
/// }
/// ```
///
/// Tool names are passed to Foundation Models unchanged. Keep names unique when
/// combining groups.
public struct ToolGroup: DynamicInstructions, Sendable {
  public let name: String
  public let description: String
  public let tools: [any FoundationModels.Tool]
  private let nestedGroupInstructions: [String]

  /// Creates a group from an existing collection of Foundation Models tools.
  public init(
    name: String,
    description: String = "A collection of related tools.",
    tools: [any FoundationModels.Tool]
  ) {
    self.name = name
    self.description = description
    self.tools = tools
    self.nestedGroupInstructions = []
  }

  /// Creates a group from tools and other groups using a result builder.
  public init(
    name: String,
    description: String = "A collection of related tools.",
    @ToolGroupBuilder tools: () -> ToolGroupBuilder.Content
  ) {
    let content = tools()
    self.name = name
    self.description = description
    self.tools = content.tools
    self.nestedGroupInstructions = content.groupInstructions
  }

  /// Contributes the group description and its tools to a dynamic profile.
  public var body: some DynamicInstructions {
    Instructions(
      ([
        "Tool group: \(name). \(description)"
      ] + nestedGroupInstructions).joined(separator: "\n")
    )
    tools
  }

  fileprivate var instructionsWhenComposed: [String] {
    ["Tool group: \(name). \(description)"] + nestedGroupInstructions
  }
}

/// A result builder for composing tools and nested ``ToolGroup`` values.
@resultBuilder
public enum ToolGroupBuilder {
  /// The accumulated tools and group context produced by the builder.
  public struct Content: Sendable {
    fileprivate let tools: [any FoundationModels.Tool]
    fileprivate let groupInstructions: [String]

    fileprivate init(
      tools: [any FoundationModels.Tool] = [],
      groupInstructions: [String] = []
    ) {
      self.tools = tools
      self.groupInstructions = groupInstructions
    }

    fileprivate static func combining(_ contents: [Content]) -> Content {
      Content(
        tools: contents.flatMap(\.tools),
        groupInstructions: contents.flatMap(\.groupInstructions)
      )
    }
  }

  public static func buildExpression<T: FoundationModels.Tool>(
    _ expression: T
  ) -> Content {
    Content(tools: [expression])
  }

  public static func buildExpression(
    _ expression: any FoundationModels.Tool
  ) -> Content {
    Content(tools: [expression])
  }

  public static func buildExpression(_ expression: ToolGroup) -> Content {
    Content(
      tools: expression.tools,
      groupInstructions: expression.instructionsWhenComposed
    )
  }

  public static func buildExpression(
    _ expression: [any FoundationModels.Tool]
  ) -> Content {
    Content(tools: expression)
  }

  public static func buildExpression<T: FoundationModels.Tool>(
    _ expression: [T]
  ) -> Content {
    Content(tools: expression)
  }

  public static func buildBlock(_ components: Content...) -> Content {
    Content.combining(components)
  }

  public static func buildOptional(_ component: Content?) -> Content {
    component ?? Content()
  }

  public static func buildEither(first component: Content) -> Content {
    component
  }

  public static func buildEither(second component: Content) -> Content {
    component
  }

  public static func buildArray(_ components: [Content]) -> Content {
    Content.combining(components)
  }

  public static func buildLimitedAvailability(_ component: Content) -> Content {
    component
  }
}

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

import FoundationModels
import FoundationModelsUtilities
import Testing

@Suite
struct ToolGroupTests {
  @Test func `composes tools and nested groups`() {
    let workspace = ToolGroup(name: "Workspace") {
      StubTool(name: "read_file")
      StubTool(name: "search_files")
    }

    let group = ToolGroup(name: "Assistant", description: "Local and remote tools.") {
      workspace
      StubTool(name: "calendar")
    }

    #expect(group.name == "Assistant")
    #expect(group.description == "Local and remote tools.")
    #expect(group.tools.map(\.name) == ["read_file", "search_files", "calendar"])
  }

  @Test func `supports conditional tools and existential collections`() {
    let includeCalendar = true
    let group = ToolGroup(name: "Conditional") {
      StubTool(name: "always")

      if includeCalendar {
        StubTool(name: "calendar")
      }
    }

    let additionalTools: [any FoundationModels.Tool] = [StubTool(name: "search")]
    let combined = ToolGroup(name: "Combined", tools: group.tools + additionalTools)
    let arrayGroup = ToolGroup(name: "Array") {
      [StubTool(name: "first"), StubTool(name: "second")]
    }

    #expect(combined.tools.map(\.name) == ["always", "calendar", "search"])
    #expect(arrayGroup.tools.map(\.name) == ["first", "second"])
  }
}

private struct StubTool: FoundationModels.Tool {
  let name: String
  var description: String { "A test tool." }

  @Generable
  struct Arguments {}

  func call(arguments: Arguments) async throws -> String { name }
}

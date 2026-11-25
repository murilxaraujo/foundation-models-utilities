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
import MCP
import Synchronization
import Testing

@testable import FoundationModelsUtilities

@Suite("MCP tools")
struct MCPToolsTests {
  @Test func hostGateRunsBeforeTheServerSeesACall() async throws {
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    let calls = Mutex(0)
    let server = Server(
      name: "TestServer",
      version: "1.0",
      capabilities: .init(tools: .init())
    )
    await server.withMethodHandler(ListTools.self) { _ in
      ListTools.Result(tools: [
        Tool(name: "ping", description: "ping tool", inputSchema: .object([:])),
      ])
    }
    await server.withMethodHandler(CallTool.self) { _ in
      calls.withLock { $0 += 1 }
      return CallTool.Result(
        content: [.text(text: "pong", annotations: nil, _meta: nil)],
        isError: false
      )
    }
    try await server.start(transport: serverTransport)

    let client = Client(name: "test", version: "1.0")
    try await client.connect(transport: clientTransport)
    let gate = ToolGate()
    let group = try await client.foundationModelToolGroup(named: "fake") { call in
      try await gate.authorize(call)
    }
    let tool = try #require(group.tools.first as? MCPToolAdapter)
    let arguments = GeneratedContent(properties: [:])

    await #expect(throws: Denied.self) {
      _ = try await tool.call(arguments: arguments)
    }
    #expect(calls.withLock { $0 } == 0)

    await gate.allow()
    _ = try await tool.call(arguments: arguments)
    #expect(calls.withLock { $0 } == 1)
    let authorized = await gate.calls
    #expect(authorized.count == 2)
    #expect(authorized.allSatisfy { $0.serverName == "fake" && $0.toolName == "ping" })

    await client.disconnect()
    await server.stop()
    await serverTransport.disconnect()
  }
}

private struct Denied: Error {}

private actor ToolGate {
  private var allowed = false
  private(set) var calls: [MCPToolCall] = []

  func allow() { allowed = true }

  func authorize(_ call: MCPToolCall) throws {
    calls.append(call)
    guard allowed else { throw Denied() }
  }
}

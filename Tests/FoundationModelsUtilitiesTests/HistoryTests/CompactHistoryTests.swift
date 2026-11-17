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
@testable import FoundationModelsUtilities
import FoundationModels
import Testing

@Suite
struct CompactHistoryTests {
  private let structuredSummary = """
    ## Objective
    - Complete the user's current task.

    ## Requirements
    - Keep the recent conversation.

    ## Decisions
    - Use a structured checkpoint.

    ## Work State
    ### Completed
    - Started the conversation.
    ### Active
    - Continue helping the user.
    ### Blocked
    - (none)

    ## Next Move
    1. Respond to the latest prompt.

    ## Relevant Files
    - (none)

    ## Important Context
    - (none)
    """

  private func promptText(_ prompt: Transcript.Prompt) -> String {
    prompt.segments.compactMap { segment in
      guard case .text(let text) = segment else { return nil }
      return text.content
    }.joined()
  }

  @Test func `writes a structured checkpoint and preserves the current prompt`() async throws {
    let mainModel = MockModel(textResponse: "Assistant response.", tokenCount: 10)
    let summarizer = MockModel(textResponse: structuredSummary, tokenCount: 10)
    let session = LanguageModelSession(
      profile: LanguageModelSession.Profile {}
        .compactHistory(entryThreshold: 3, keepRecentEntries: 8, model: summarizer)
        .model(mainModel)
    )

    _ = try await session.respond(to: "First request.")
    _ = try await session.respond(to: "Second request.")
    _ = try await session.respond(to: "Current request.")

    let prompt = try #require(session.transcript.compactMap(\.prompt).last)
    let text = promptText(prompt)
    #expect(text.contains("<conversation-checkpoint>"))
    #expect(text.contains("<summary>"))
    #expect(text.contains("## Objective"))
    #expect(text.contains("<recent-context>"))
    #expect(text.contains("User: Second request."))
    #expect(!text.contains("User: First request."))
    #expect(text.hasSuffix("Current request."))
  }

  @Test func `updates a prior checkpoint on later compaction passes`() async throws {
    let mainModel = MockModel(textResponse: "Assistant response.", tokenCount: 10)
    let recorder = TranscriptRecorder()
    let summarizer = MockModel(
      textResponse: structuredSummary,
      tokenCount: 10,
      recorder: recorder
    )
    let session = LanguageModelSession(
      profile: LanguageModelSession.Profile {}
        .compactHistory(entryThreshold: 1, keepRecentEntries: 1, model: summarizer)
        .model(mainModel)
    )

    _ = try await session.respond(to: "First request.")
    _ = try await session.respond(to: "Second request.")
    _ = try await session.respond(to: "Third request.")

    #expect(recorder.transcripts.count == 2)
    let secondCompactionInput = try #require(recorder.transcripts.last).history.chatLog()
    #expect(secondCompactionInput.contains("<conversation-checkpoint>"))
    #expect(secondCompactionInput.contains("## Objective"))
    #expect(secondCompactionInput.contains("Third request."))
  }

  @Test func `manually compacts history without a trailing prompt`() async throws {
    let mainModel = MockModel(textResponse: "Assistant response.", tokenCount: 10)
    let summarizer = MockModel(textResponse: structuredSummary, tokenCount: 10)
    let session = LanguageModelSession(model: mainModel)

    _ = try await session.respond(to: "First request.")
    _ = try await session.respond(to: "Second request.")

    let compacted = try await HistoryCompactor.compact(
      history: Array(session.transcript.history),
      model: summarizer,
      keepRecentEntries: 1
    )

    let prompt = try #require(compacted.compactMap(\.prompt).last)
    let text = promptText(prompt)
    #expect(compacted.count == 1)
    #expect(text.contains("<conversation-checkpoint>"))
    #expect(text.contains("User: Second request."))
    #expect(text.contains("Assistant: Assistant response."))
  }

  @Test func `retries once and fails without writing an unstructured checkpoint`() async throws {
    let mainModel = MockModel(textResponse: "Assistant response.", tokenCount: 10)
    let recorder = TranscriptRecorder()
    let summarizer = MockModel(
      textResponse: "This summary has no required heading.",
      tokenCount: 10,
      recorder: recorder
    )
    let session = LanguageModelSession(
      profile: LanguageModelSession.Profile {}
        .compactHistory(entryThreshold: 1, model: summarizer)
        .model(mainModel)
    )

    _ = try await session.respond(to: "First request.")

    await #expect(throws: CompactHistoryError.summaryMissingStructure) {
      try await session.respond(to: "Second request.")
    }

    #expect(recorder.transcripts.count == 2)
    let historyText = session.transcript.history.chatLog()
    #expect(historyText.contains("First request."))
    #expect(!historyText.contains("<conversation-checkpoint>"))
  }
}

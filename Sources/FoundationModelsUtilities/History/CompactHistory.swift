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
public import Foundation

extension LanguageModelSession.DynamicProfile {
  /// Returns a modified profile that compacts the transcript into a structured
  /// checkpoint when it exceeds an entry threshold.
  ///
  /// The checkpoint records the objective, requirements, decisions, work
  /// state, next move, relevant files, and important context. On later passes,
  /// the summarizer updates the existing checkpoint with newer conversation
  /// history. The most recent complete exchange is retained as recent context
  /// when possible, and the current prompt is preserved verbatim.
  ///
  /// Unlike OpenCode's compaction service, this modifier measures history by
  /// transcript entries rather than tokens. `keepRecentEntries` is an entry
  /// count; the modifier backs up to a prompt boundary to avoid splitting an
  /// exchange, so it may retain more entries than requested.
  ///
  /// ```swift
  /// Profile {
  ///   Instructions("A coding assistant that helps with the user's task.")
  /// }
  /// .compactHistory(entryThreshold: 50, keepRecentEntries: 8, model: model)
  /// ```
  ///
  /// - Parameters:
  ///   - entryThreshold: The transcript entry count above which compaction
  ///     runs.
  ///   - keepRecentEntries: The target number of recent entries to retain
  ///     verbatim beside the summary. The retained range starts at a prompt
  ///     boundary and can exceed this count. Defaults to 8.
  ///   - model: The language model used to generate the checkpoint.
  ///   - instructions: Optional custom instructions for the compaction model.
  ///     The output must still contain at least one heading from the required
  ///     checkpoint template.
  /// - Returns: A profile that compacts its transcript when it exceeds the
  ///   specified entry threshold.
  public func compactHistory<Model: LanguageModel>(
    entryThreshold: Int,
    keepRecentEntries: Int = 8,
    model: Model,
    instructions: Instructions? = nil
  ) -> some DynamicProfile {
    modifier(
      CompactHistoryModifier(
        entryThreshold: entryThreshold,
        keepRecentEntries: keepRecentEntries,
        model: model,
        instructions: instructions
      )
    )
  }
}

/// An error raised when the compaction model does not produce the required
/// structured checkpoint after one retry.
public enum CompactHistoryError: Error, LocalizedError, Sendable, Equatable {
  case summaryMissingStructure

  public var errorDescription: String? {
    switch self {
    case .summaryMissingStructure:
      return "Compaction summary did not match the required template"
    }
  }
}

/// Produces an OpenCode-style structured checkpoint for a transcript.
///
/// Use this type when compaction must be invoked directly, such as from a
/// user-controlled action. ``LanguageModelSession/DynamicProfile/compactHistory(entryThreshold:keepRecentEntries:model:instructions:)``
/// uses the same compactor automatically when the transcript exceeds an entry
/// threshold.
public enum HistoryCompactor {
  /// Replaces the supplied conversation history with a structured checkpoint.
  ///
  /// If the history ends with a prompt, the compactor keeps that prompt's
  /// segments and generation settings on the replacement entry. Without a
  /// trailing prompt, the replacement is a checkpoint prompt ready for the
  /// next user turn.
  public static func compact<Model: LanguageModel>(
    history entries: [Transcript.Entry],
    model: Model,
    keepRecentEntries: Int = 8,
    instructions: Instructions? = nil
  ) async throws -> [Transcript.Entry] {
    guard !entries.isEmpty else {
      return entries
    }

    let currentPrompt: Transcript.Prompt?
    if case .prompt(let prompt) = entries.last {
      currentPrompt = prompt
    } else {
      currentPrompt = nil
    }

    let textRepresentation = entries.chatLog()
    guard !textRepresentation.isEmpty else {
      return entries
    }

    let isUpdate = entries.contains(where: CompactHistorySupport.isCheckpoint)
    let defaultInstructions =
      isUpdate
      ? CompactHistorySupport.updateInstructions
      : CompactHistorySupport.summaryInstructions
    let session = LanguageModelSession(
      model: model,
      instructions: instructions ?? Instructions { defaultInstructions }
    )

    var summary = try await session.respond(
      to: Prompt {
        "Summarize this conversation:\n\n\(textRepresentation)"
      }
    ).content

    if !CompactHistorySupport.containsExpectedHeading(summary) {
      summary = try await session.respond(to: Prompt { CompactHistorySupport.nudge }).content
    }
    guard CompactHistorySupport.containsExpectedHeading(summary) else {
      throw CompactHistoryError.summaryMissingStructure
    }

    let recentContext = CompactHistorySupport.recentContext(
      in: entries,
      excludingTrailingPrompt: currentPrompt != nil,
      keepRecentEntries: keepRecentEntries
    )
    let checkpoint = CompactHistorySupport.checkpoint(
      summary: summary,
      recentContext: recentContext
    )
    let checkpointSegment = Transcript.Segment.text(
      Transcript.TextSegment(content: checkpoint)
    )
    let prompt = Transcript.Prompt(
      id: UUID().uuidString,
      metadata: currentPrompt?.metadata ?? [:],
      segments: [checkpointSegment] + (currentPrompt?.segments ?? []),
      options: currentPrompt?.options ?? GenerationOptions(),
      responseFormat: currentPrompt?.responseFormat,
      contextOptions: currentPrompt?.contextOptions ?? ContextOptions()
    )
    return [.prompt(prompt)]
  }
}

private struct CompactHistoryModifier<Model: LanguageModel>: LanguageModelSession
    .DynamicProfileModifier
{
  let entryThreshold: Int
  let keepRecentEntries: Int
  let model: Model
  let instructions: Instructions?

  @SessionProperty(\.history)
  var history

  func body(content: Content) -> some DynamicProfile {
    content.onPrompt {
      guard history.count > entryThreshold else {
        return
      }
      guard case .prompt = history.last else {
        return
      }
      let compactedHistory = try await HistoryCompactor.compact(
        history: Array(history),
        model: model,
        keepRecentEntries: keepRecentEntries,
        instructions: instructions
      )
      history.replaceSubrange(history.startIndex..<history.endIndex, with: compactedHistory)
    }
  }
}

private enum CompactHistorySupport {
  static let summaryInstructions = """
    Summarize only what the user and the assistant said and did. Leave out instructions and setup the assistant was given rather than told by the user: repository conventions, instruction files, and environment details. The next agent receives those separately.

    You MUST use this format for your response (you may omit sections that aren't applicable). Do not include the <template> tags in your response.
    <template>
    ## Objective
    - [one or two brief sentences describing what the user is trying to accomplish]

    ## Requirements
    - [constraints, preferences, requirements, and scope boundaries stated by the user, or "(none)"]

    ## Decisions
    - [decisions already made and why, or "(none)"]

    ## Work State
    Break the objective into smaller goals and report which are completed, which are being worked on, and which are blocked.
    ### Completed
    - [goals that have been completed; otherwise "(none)"]

    ### Active
    - [goals currently being worked on; otherwise "(none)"]

    ### Blocked
    - [anything blocking progress, and why; otherwise "(none)"]

    ## Next Move
    1. [ordered list of next actions, or "(none)"]

    ## Relevant Files
    List the files and directories, other than the current working directory, that another agent would need to open to continue this work. Include at most 15, most important first. Do not list every file that was read or changed. Include paths outside the current working directory when relevant. If none, write "(none)".
    - `[file or directory path]`: [brief reason it matters]

    ## Important Context
    - [facts the next agent cannot continue without and cannot easily find on its own; or "(none)"]
    </template>

    Rules:
    - Keep each section concise. Use terse, single-line bullets, not prose paragraphs or nested lists.
    - Prefer short references over detailed restatement. It is fine to leave out information the next agent can recover from the code or the files listed above.
    - Preserve exact file paths, symbols, commands, error strings, URLs, and identifiers.
    - Carry forward only user questions or requests that remain unanswered or require further action. Do not repeat ones that newer history has answered or resolved. Preserve exact wording when carrying one forward.
    - Preserve consequential workflow state, including whether changes are uncommitted, committed, pushed, under review, or merged.
    - Do not mention the summary process or that context was compacted.
    - Do not continue the task or call tools.
    - Return only the structured summary. Do not include a preamble, explanation, or other commentary.
    """

  static var updateInstructions: String {
    """
    Update the existing checkpoint in the conversation above into one consolidated summary.
    Newer history always takes precedence over the existing checkpoint. Preserve previous information unless newer history clearly contradicts, supersedes, resolves, or makes it stale. If something is no longer relevant to continuing the work, you may remove it.
    Incorporate newer requirements, decisions, progress, and context. Reconcile Work State and Next Move: move completed work out of Active, remove resolved blockers and answered questions, and preserve unresolved or pending work.
    Return only the updated Markdown sections. Do not reproduce the <conversation-checkpoint>, <summary>, or <recent-context> wrapper tags from the previous checkpoint.

    \(summaryInstructions)
    """
  }

  static let nudge = """
    The previous response did not fill in the required summary template. Do not call tools. Return the summary as text using the exact section headings from the template.
    """

  private static let checkpointMarker = "<conversation-checkpoint>"
  private static let summaryHeadings = [
    "## Objective",
    "## Requirements",
    "## Decisions",
    "## Work State",
    "### Completed",
    "### Active",
    "### Blocked",
    "## Next Move",
    "## Relevant Files",
    "## Important Context"
  ]

  static func isCheckpoint(_ entry: Transcript.Entry) -> Bool {
    guard case .prompt(let prompt) = entry else {
      return false
    }
    return prompt.segments.contains { segment in
      guard case .text(let text) = segment else {
        return false
      }
      return text.content.contains(checkpointMarker)
    }
  }

  static func containsExpectedHeading(_ text: String) -> Bool {
    text.split(separator: "\n").contains { line in
      summaryHeadings.contains(String(line).trimmingCharacters(in: .whitespaces))
    }
  }

  /// Retains the newest complete exchange from the tail that fits the entry
  /// target. Existing checkpoint content is updated, not copied into the tail.
  static func recentContext(
    in entries: [Transcript.Entry],
    excludingTrailingPrompt: Bool,
    keepRecentEntries: Int
  ) -> String {
    let prior = excludingTrailingPrompt ? Array(entries.dropLast()) : entries
    let keepCount = max(0, keepRecentEntries)
    guard keepCount > 0, !prior.isEmpty else {
      return ""
    }

    let checkpointIndex = prior.firstIndex(where: isCheckpoint)
    let lowerBound = checkpointIndex.map { $0 + 1 } ?? 0
    guard lowerBound < prior.endIndex else {
      return ""
    }

    let requestedStart = max(lowerBound, prior.count - keepCount)
    let promptBoundary = prior.indices.last { index in
      index >= lowerBound && isPrompt(prior[index])
    }
    let cutoffBoundary = prior.indices.last { index in
      index >= lowerBound && index <= requestedStart && isPrompt(prior[index])
    }
    let start = (requestedStart == lowerBound ? promptBoundary : cutoffBoundary) ?? lowerBound

    // If the retained range would duplicate the entire first conversation,
    // let the structured summary carry it instead.
    guard start > lowerBound || checkpointIndex != nil else {
      return ""
    }
    return prior[start...].chatLog()
  }

  private static func isPrompt(_ entry: Transcript.Entry) -> Bool {
    if case .prompt = entry { return true }
    return false
  }

  static func checkpoint(summary: String, recentContext: String) -> String {
    """
    <conversation-checkpoint>
    <summary>
    \(summary)
    </summary>
    <recent-context>
    \(recentContext)
    </recent-context>
    </conversation-checkpoint>

    """
  }
}

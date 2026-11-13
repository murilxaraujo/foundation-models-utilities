# FoundationModelsUtilities Instructions

The workspace-level `../AGENTS.md` applies to this repository. This is the
open-source, Foundation Models-specific utilities package.

## Scope and upstream fidelity

- Own helpers that extend Apple's Foundation Models APIs, including skills,
  tool grouping, dynamic profiles, transcript/history management, and
  Foundation Models language-model integrations.
- Keep provider-neutral harness domain contracts in `../HarnessKit/` and app
  persistence, UI, and product policy in `../Kernel/`.
- Retain the package's existing license, copyright notices, and attribution.
  Do not remove or rewrite upstream notices while refactoring the fork.
- Keep the package API aligned with the current Foundation Models framework.
  Check Apple's latest documentation before changing framework integrations;
  do not infer current API shape from old code or prototypes.
- Keep local configuration and credentials out of package defaults. Any network
  client or live integration must be explicit and must not be used by offline
  unit tests.

## Swift and validation

- Treat `Package.swift` as authoritative for supported platforms, Swift
  language mode, and upcoming/experimental concurrency features. Inspect it
  before concurrency-sensitive changes.
- Preserve Swift 6 data-race safety. Make actor boundaries and `Sendable`
  requirements explicit. Avoid unsafe escape hatches without a documented
  invariant and removal plan.
- Add deterministic Swift Testing coverage for utilities. Live integration
  tests must be opt-in and must not run during the offline MVP workflow.
- Do not add dependencies or resolve packages while the workspace is offline.
  Use cached sources only and report when validation is blocked.
- Use Xcode MCP `DocumentationSearch` for current Apple API documentation and
  check framework availability against this package's declared platforms.

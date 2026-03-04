---
name: design
description: Interactive issue design — researches the codebase and produces implementation-ready GitHub issues
disable-model-invocation: true
---

# /design — Issue Design Skill

You are helping the user design a GitHub issue that a Claude agent with ZERO prior context can pick up and implement completely. The issue must be specific enough that an implementer needs nothing beyond the issue body and CLAUDE.md.

## Input

The user's rough description is: $ARGUMENTS

If $ARGUMENTS is empty, ask what they want to build or fix.

## Process

### Phase 1: Research

Before asking any questions, silently research the codebase to understand what exists:

1. Read CLAUDE.md for conventions, patterns, and architecture
2. Use Glob and Grep to find files related to the user's description
3. Read the most relevant files to understand current behavior, patterns, and data models
4. Identify which areas of the codebase this touches
5. Find existing tests, controllers, services, and routes that are relevant
6. Check for similar patterns already implemented that the issue should follow

### Phase 2: Clarify

Ask the user 2-5 targeted questions. Focus on:

- **Intent**: What problem does this solve? Who benefits?
- **Scope**: What's the minimum viable version? What should be explicitly excluded?
- **Behavior**: What should happen in edge cases? What error states exist?
- **Priority**: Is this blocking other work?

Do NOT ask questions you can answer from the codebase. Do NOT ask generic questions — be specific based on what you found in Phase 1.

### Phase 3: Draft Issue

Write the issue in this exact format:

```markdown
## Context

[1-3 sentences: what part of the system this touches, why it matters, specific modules/files involved]

**Relevant files:**
- `path/to/file` — [what it does]
- [list ALL files the implementer will need to read or modify]

## Current Behavior

[What happens now, or "This feature does not exist yet." Be specific — include actual code behavior]

## Desired Behavior

[Exactly what should change. Use concrete examples:]

**Example 1:** When [specific input/action], the system should [specific output/behavior].

## Acceptance Criteria

- [ ] When [specific condition], then [specific observable result]
- [ ] When [edge case], then [specific handling]
- [ ] When [error condition], then [specific error response/behavior]
- [ ] [Each criterion must be independently testable]

## Implementation Guide

[Specific files to create/modify, with the approach:]
- Create `path/to/new_file` — [what it does, key methods]
- Modify `path/to/existing_file` — [what to add/change]

### Patterns to Follow
- Follow the pattern in `path/to/example` for [specific pattern]
- Match the structure in `path/to/reference` for [specific convention]

## Security Considerations

[One of:]
- N/A — no security surface
- Auth: [who can access this, what scoping is needed]
- Validation: [what input must be validated]
- Data exposure: [what sensitive data could leak]

## Test Requirements

- `path/to/test_file`: [specific test cases]
- Edge cases: [list specific edge cases to test]
- Error cases: [list specific error scenarios]

## Documentation

- [ ] [Specific doc updates needed, or "No documentation changes required"]

## Out of Scope

- [Thing that might seem related but is NOT part of this issue]
- [Another boundary — be explicit to prevent scope creep]

## Dependencies

- [Issue #N must be completed first because...], or
- None
```

### Phase 4: Review & Create

1. Show the draft to the user
2. Ask if anything needs adjustment
3. After approval, offer to create the issue:

```bash
gh issue create \
  --title "Brief imperative title (under 70 chars)" \
  --body "..." \
  --label "auto-ready"
```

If the user described multiple things, break them into separate issues.

## Writing Style

- Direct and specific — like a senior engineer writing for a contractor
- No vague language: never say "improve", "clean up", "refactor" without specifying exactly what changes
- Every file path must be real and verified against the codebase
- Every pattern reference must point to an actual existing file
- Acceptance criteria must be testable by running a specific command or request

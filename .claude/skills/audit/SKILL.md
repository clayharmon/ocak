---
name: audit
description: Comprehensive codebase audit — security, error handling, patterns, tests, data, dependencies
disable-model-invocation: true
---

# /audit — Codebase Audit

Run a comprehensive sweep of the codebase across multiple dimensions. Produces a prioritized report with actionable findings.

## Input

Optional scope argument: $ARGUMENTS

Supported scopes: `security`, `errors`, `patterns`, `tests`, `data`, `dependencies`, or empty for all.

## Process

### Phase 1: Orientation

1. Read CLAUDE.md for architecture and conventions
2. Map the project structure using Glob to understand directories and file organization

### Phase 2: Static Analysis Tools

Run all available tools and capture output. Do NOT stop if a tool fails.

```bash
bundle exec rubocop 2>&1 || true
```

### Phase 3: Manual Analysis

For each dimension below, perform targeted searches and reads. Only run dimensions matching $ARGUMENTS (or all if no argument).

#### Security (`security`)

Search for and evaluate:
- Auth gaps — endpoints or handlers missing authentication
- Unvalidated inputs — user data used without validation
- SQL/command injection — string interpolation in queries or shell commands
- Hardcoded secrets — passwords, API keys, tokens in source code
- Mass assignment — unfiltered parameters in create/update operations

#### Error Handling (`errors`)

- Bare rescue/catch blocks without specific types
- Swallowed exceptions (caught with no re-raise, logging, or handling)
- Inconsistent error response patterns
- Missing error handling in external calls (HTTP, database, file I/O)

#### Bad Patterns (`patterns`)

- God classes/modules (files > 200 lines)
- TODO/FIXME/HACK/XXX comments
- Dead code or commented-out code
- Code duplication
- Tight coupling between unrelated modules

#### Test Gaps (`tests`)

- Public methods/functions without corresponding tests
- Tests that don't assert anything meaningful
- Skipped or pending tests
- Missing edge case and error path tests

#### Data Issues (`data`)

- N+1 query candidates
- Missing database indexes
- Unbounded queries (no limit/pagination)
- Incorrect data types (e.g., float for money)

#### Dependencies (`dependencies`)

- Outdated packages with known vulnerabilities
- Unused dependencies
- Overly broad version constraints

### Phase 4: Report

Output findings grouped by severity. Every finding must have a specific file path and line number.

```
# Codebase Audit Report

**Scope**: [all | security | errors | patterns | tests | data | dependencies]

## Critical (fix immediately)

### [Finding title]
**File**: `path/to/file:42`
**Category**: [Security | Error Handling | Pattern | Test Gap | Data | Dependency]
**Issue**: [Specific description of what's wrong]
**Impact**: [What could go wrong]
**Fix**: [Exact steps to remediate]

## High (fix soon)
...

## Medium (should fix)
...

## Low (consider fixing)
...

## Summary

| Category | Critical | High | Medium | Low |
|----------|----------|------|--------|-----|
| Security | N | N | N | N |
| Error Handling | N | N | N | N |
| Patterns | N | N | N | N |
| Test Gaps | N | N | N | N |
| Data | N | N | N | N |
| Dependencies | N | N | N | N |
| **Total** | **N** | **N** | **N** | **N** |
```

### Phase 5: Issue Generation

After presenting the report, offer:

> I found N critical and N high findings. Want me to generate GitHub issues for them?
> Each issue will follow the /design format so they can be processed by the autonomous pipeline.

If the user accepts, generate issues using the /design format and offer to create them with `gh issue create --label "auto-ready"`.

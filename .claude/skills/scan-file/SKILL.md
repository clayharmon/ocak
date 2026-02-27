---
name: scan-file
description: Deep single-file analysis — bugs, security, patterns, test coverage
disable-model-invocation: true
argument-hint: <file-path>
---

# /scan-file — Single File Analysis

Deep analysis of a single file and its dependency graph. Finds bugs, security issues, bad patterns, missing error handling, and test gaps.

## Input

File path: $ARGUMENTS

If $ARGUMENTS is empty, ask which file to scan.

## Process

### Phase 1: Read the Target File

1. Read the file specified by $ARGUMENTS in full
2. Identify the file's role based on its location and contents

### Phase 2: Read Dependencies

Find and read all files this file imports, requires, or inherits from (skip third-party packages).

### Phase 3: Find the Test File

Determine the corresponding test file based on project conventions. If the test file exists, read it. If it doesn't exist, note this as a finding.

### Phase 4: Analysis

Check every line for:

#### Bugs
- Off-by-one errors in loops or ranges
- Nil/null reference risks
- Race conditions in concurrent code
- Incorrect method signatures or wrong argument order
- Missing return values

#### Security
- SQL injection (string interpolation in queries)
- Command injection (system calls with user input)
- Path traversal (file operations with user-supplied paths)
- Missing authorization checks
- Information leakage in error messages
- Hardcoded secrets

#### Patterns
- Violations of project conventions (read CLAUDE.md for reference)
- Methods that are too long (> 20 lines)
- Classes with too many responsibilities
- Dead code (unreachable branches, unused variables)

#### Error Handling
- Bare rescue/catch without specific exception types
- Swallowed exceptions
- Missing error handling for external calls
- Inconsistent error response format

#### Edge Cases
- Empty collections (`.first` on possibly empty array)
- Zero/negative values in calculations
- Very large inputs (unbounded queries, no pagination)
- Concurrent access (race conditions)

#### Test Coverage
Compare the public interface of the target file against the test file:
- List every public method/exported function
- For each, check if the test file has a corresponding test
- Check if error paths are tested
- Check if edge cases are tested

### Phase 5: Output

```
# Scan: `path/to/file`

## Summary
[1-2 sentence overview]

## Findings

### Line N: [Title]
**Severity**: Critical / High / Medium / Low
**Category**: Bug / Security / Pattern / Error Handling / Edge Case
**Issue**: [What's wrong]
**Fix**: [Exact fix]

## Test Coverage

| Method/Function | Tested | Edge Cases | Error Path |
|----------------|--------|------------|------------|
| `method_name` | yes/no | yes/no | yes/no |

**Missing tests**:
- `method_name` with nil input
- [specific untested scenarios]

## Score: N/10
[Brief justification]
```

### Phase 6: Offer Actions

After presenting findings, offer:

1. **Fix issues** — "Want me to fix the issues I found?"
2. **Generate issue** — "Want me to create a GitHub issue for these findings?"
3. **Both** — Fix what's safe to fix inline, create an issue for the rest

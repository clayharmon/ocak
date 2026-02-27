# Ocak

**Autonomous GitHub issue processing pipeline using Claude Code.**

Ocak sets up and runs a multi-agent pipeline that takes GitHub issues from design to merged PR — automatically. Write a well-structured issue, label it, and let the agents implement, review, fix, audit, document, and merge. In parallel.

*Ocak means "forge" in Turkish. Also: let 'em cook.*

## Quick Start

```bash
gem install ocak

# In your project directory:
ocak init

# Create an issue (interactive):
# Inside Claude Code, run /design

# Process all ready issues:
ocak run --once --watch

# Or run a single issue:
ocak run --single 42 --watch
```

## How It Works

### The Pipeline

```
  /design        Label           Pipeline
  ┌──────┐    ┌──────────┐    ┌───────────────────────────────────────────┐
  │ User │───>│auto-ready│───>│ implement → review → fix → security →    │
  │ idea │    │  label   │    │ document → audit → merge PR              │
  └──────┘    └──────────┘    └───────────────────────────────────────────┘
                                 │           │          │
                                 ▼           ▼          ▼
                              worktree   read-only   sequential
                              per issue  reviews     rebase+merge
```

1. **Design** — Use `/design` in Claude Code to create implementation-ready issues
2. **Label** — Issues get the `auto-ready` label
3. **Plan** — The planner agent groups parallelizable issues into batches
4. **Execute** — Each issue gets its own git worktree and runs through the pipeline
5. **Merge** — Completed work is rebased, tested, and merged sequentially

### Agents

Ocak uses 8 specialized agents, each with scoped tool permissions:

| Agent | Role | Tools | Model |
|-------|------|-------|-------|
| **implementer** | Write code and tests | Read, Write, Edit, Bash | opus |
| **reviewer** | Check patterns, tests, quality | Read, Grep, Glob (read-only) | sonnet |
| **security-reviewer** | OWASP Top 10, auth, injection | Read, Grep, Glob, Bash | sonnet |
| **auditor** | Pre-merge gate on changed files | Read, Grep, Glob (read-only) | sonnet |
| **documenter** | Add missing docs | Read, Write, Edit | sonnet |
| **merger** | Create PR, merge, close issue | Read, Grep, Bash | sonnet |
| **planner** | Determine safe parallelization | Read, Grep, Glob (read-only) | sonnet |
| **pipeline** | Self-contained orchestrator | All tools | opus |

### Skills

Interactive Claude Code skills for human-in-the-loop work:

- **`/design`** — Research codebase, ask clarifying questions, produce an implementation-ready issue
- **`/audit [scope]`** — Comprehensive codebase sweep (security, patterns, tests, data, dependencies)
- **`/scan-file <path>`** — Deep single-file analysis with test coverage check
- **`/debt`** — Technical debt tracker with risk scoring

### Label State Machine

```
auto-ready ──→ in-progress ──→ completed
                    │
                    └──→ pipeline-failed
```

## Configuration

`ocak init` generates `ocak.yml` at your project root:

```yaml
# Auto-detected project stack
stack:
  language: ruby
  framework: rails
  test_command: "bundle exec rspec"
  lint_command: "bundle exec rubocop -A"
  security_commands:
    - "bundle exec brakeman -q"
    - "bundle exec bundler-audit check"

# Pipeline settings
pipeline:
  max_parallel: 3        # Concurrent worktrees
  poll_interval: 60      # Seconds between polls
  worktree_dir: ".claude/worktrees"
  log_dir: "logs/pipeline"

# GitHub labels
labels:
  ready: "auto-ready"
  in_progress: "in-progress"
  completed: "completed"
  failed: "pipeline-failed"

# Pipeline steps — add, remove, reorder
steps:
  - agent: implementer
    role: implement
  - agent: reviewer
    role: review
  - agent: implementer
    role: fix
    condition: has_findings     # Only runs if reviewer found 🔴
  - agent: reviewer
    role: verify
    condition: had_fixes        # Only runs if fixes were made
  - agent: security_reviewer
    role: security
  - agent: implementer
    role: fix
    condition: has_findings
  - agent: documenter
    role: document
  - agent: auditor
    role: audit
  - agent: merger
    role: merge

# Override agent files
agents:
  implementer: .claude/agents/implementer.md
  reviewer: .claude/agents/reviewer.md
  # ...
```

## Customization

### Swap Agents

Point any agent to a custom file:

```yaml
agents:
  reviewer: .claude/agents/my-custom-reviewer.md
```

### Change Pipeline Steps

Remove steps you don't need, add custom ones, reorder:

```yaml
steps:
  - agent: implementer
    role: implement
  - agent: reviewer
    role: review
  - agent: merger
    role: merge
```

### Add Custom Agents

Create a markdown file with YAML frontmatter:

```markdown
---
name: my-agent
description: Does something specific
tools: Read, Glob, Grep, Bash
model: sonnet
---

# My Custom Agent

[Instructions for the agent...]
```

Reference it in `ocak.yml`:

```yaml
agents:
  my_agent: .claude/agents/my-agent.md

steps:
  - agent: my_agent
    role: custom_step
```

## Writing Good Issues

The `/design` skill produces issues formatted for zero-context agents. Key sections:

- **Context** — What part of the system, with specific file paths
- **Acceptance Criteria** — "When X, then Y" format, each independently testable
- **Implementation Guide** — Exact files to create/modify
- **Patterns to Follow** — References to actual files in the codebase
- **Security Considerations** — Auth, validation, data exposure
- **Test Requirements** — Specific test cases with file paths
- **Out of Scope** — Explicit boundaries to prevent scope creep

Think of it as writing a ticket for a contractor who has never seen the codebase. Everything they need should be in the issue body.

## CLI Reference

```
ocak init [--force] [--no-ai]    Set up pipeline in current project
ocak run [options]                Run the pipeline
  --watch                         Stream agent activity with color
  --single N                      Run one issue, no worktrees
  --dry-run                       Show plan without executing
  --once                          Process current batch and exit
  --max-parallel N                Limit concurrency (default: 3)
  --poll-interval N               Seconds between polls (default: 60)
ocak status                       Show pipeline state
ocak clean                        Remove stale worktrees
ocak design [description]         Launch issue design session
ocak audit [scope]                Run codebase audit
ocak debt                         Track technical debt
```

## FAQ

### How much does it cost?

Each issue typically costs $2-15 in API usage depending on complexity. The implementer (opus) is the most expensive step. Reviews (sonnet) are cheaper. You can monitor costs in the `--watch` output.

### Is it safe?

- Review agents are read-only (no Write/Edit tools)
- The merger agent creates PRs with full context
- Sequential merging prevents conflicts
- Failed pipelines are labeled and logged
- You can always `--dry-run` first

### What if it breaks?

- Issues are labeled `pipeline-failed` with a comment explaining what went wrong
- Worktrees are cleaned up automatically
- Run `ocak clean` to remove any stragglers
- Check `logs/pipeline/` for detailed logs

### Can I run one issue manually?

```bash
ocak run --single 42 --watch
```

This runs the full pipeline for issue #42 in your current checkout (no worktree).

### How do I pause the pipeline?

Just stop the `ocak run` process. Issues that are `in-progress` will stay labeled — remove the label manually or let the next run pick them up.

### What languages are supported?

`ocak init` detects: Ruby, TypeScript/JavaScript, Python, Rust, Go, Java, Elixir. The agents are generated with stack-specific instructions. For unsupported languages, agents are generated with generic instructions that you can customize.

## Development

```bash
git clone https://github.com/clayharmon/ocak
cd ocak
bundle install
bundle exec rspec
bundle exec rubocop
```

## Contributing

Bug reports and pull requests are welcome on GitHub.

## License

MIT License. See [LICENSE.txt](LICENSE.txt).

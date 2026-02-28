# Ocak

*Ocak (pronounced "oh-JAHK") is Turkish for "forge" or "hearth" — the place where raw material meets fire and becomes something useful. Also: let 'em cook.*

Multi-agent pipeline that processes GitHub issues autonomously with Claude Code. You write an issue, label it, and ocak runs it through implement -> review -> fix -> security review -> document -> merge. Each issue gets its own worktree so they can run in parallel.

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
ocak run 42 --watch
```

## How It Works

### The Pipeline

```
  /design        Label           Pipeline
  ┌──────┐    ┌──────────┐    ┌───────────────────────────────────────────┐
  │ User │───>│auto-ready│───>│ implement → review → fix → security →    │
  │ idea │    │  label   │    │ document → merge PR                      │
  └──────┘    └──────────┘    └───────────────────────────────────────────┘
                                 │           │          │
                                 ▼           ▼          ▼
                              worktree   read-only   sequential
                              per issue  reviews     rebase+merge
```

1. **Design** — `/design` in Claude Code walks you through creating an issue thats detailed enough for agents to work from
2. **Label** — slap the `auto-ready` label on it
3. **Plan** — planner agent figures out which issues can safely run in parallel
4. **Execute** — each issue gets a worktree, runs through the pipeline steps
5. **Merge** — completed work gets rebased, tested, and merged sequentially

### Agents

8 agents, each with scoped tool permisions:

| Agent | Role | Tools | Model |
|-------|------|-------|-------|
| **implementer** | Write code and tests | Read, Write, Edit, Bash | opus |
| **reviewer** | Check patterns, tests, quality | Read, Grep, Glob (read-only) | sonnet |
| **security-reviewer** | OWASP Top 10, auth, injection | Read, Grep, Glob, Bash | sonnet |
| **auditor** | Post-pipeline security gate (triggered by `--audit` flag) | Read, Grep, Glob (read-only) | sonnet |
| **documenter** | Add missing docs | Read, Write, Edit | sonnet |
| **merger** | Create PR, merge, close issue | Read, Grep, Bash | sonnet |
| **planner** | Determine safe parallelization | Read, Grep, Glob (read-only) | sonnet |
| **pipeline** | Self-contained orchestrator | All tools | opus |

### Skills

Interactive skills for use inside Claude Code (not standalone CLI commands):

- `/design` — walks through your codebase, asks questions, produces a detailed issue
- `/audit [scope]` — codebase sweep for security, patterns, tests, data, dependencies
- `/scan-file <path>` — deep single-file analysis with test coverage check
- `/debt` — tech debt tracker with risk scoring

### Complexity Classification

The planner classifies each issue as `simple` or `full`. Simple issues skip steps tagged with `complexity: full` (second fix pass, documenter) — so a typo fix doesn't burn through the whole pipeline.

### Monorepo Support

`ocak init` detects npm/pnpm workspaces, Cargo workspaces, Go workspaces, and Lerna packages. Detected packages are passed to agent templates so they scope their work to the right subdirectory.

### Label State Machine

```
auto-ready ──→ auto-doing ──→ completed
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
  setup_command: "bundle install"       # Runs in new worktrees before pipeline starts
  security_commands:
    - "bundle exec brakeman -q"
    - "bundle exec bundler-audit check"

# Pipeline settings
pipeline:
  max_parallel: 5        # Concurrent worktrees
  poll_interval: 60      # Seconds between polls
  worktree_dir: ".claude/worktrees"
  log_dir: "logs/pipeline"
  cost_budget: 20.0      # Optional: max USD spend per pipeline run

# Safety controls
safety:
  allowed_authors: []         # Restrict to specific GitHub usernames (empty = allow all)
  require_comment: false      # Require a confirmation comment before processing
  max_issues_per_run: 5       # Cap issues per polling cycle

# GitHub labels
labels:
  ready: "auto-ready"
  in_progress: "auto-doing"
  completed: "completed"
  failed: "pipeline-failed"

# Pipeline steps — add, remove, reorder as you like
steps:
  - agent: implementer
    role: implement
  - agent: reviewer
    role: review
  - agent: implementer
    role: fix
    condition: has_findings     # Only runs if reviewer found issues
  - agent: reviewer
    role: verify
    condition: had_fixes        # Only runs if fixes were made
  - agent: security-reviewer
    role: security
  - agent: implementer
    role: fix
    condition: has_findings
    complexity: full            # Skipped for simple issues
  - agent: documenter
    role: document
    complexity: full            # Skipped for simple issues
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

Point any agent at a custom file:

```yaml
agents:
  reviewer: .claude/agents/my-custom-reviewer.md
```

### Change Pipeline Steps

Remove steps you don't need, add your own, reorder them:

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

Then reference it in `ocak.yml`:

```yaml
agents:
  my_agent: .claude/agents/my-agent.md

steps:
  - agent: my_agent
    role: custom_step
```

## Writing Good Issues

The `/design` skill produces issues formatted for zero-context agents. Think of it as writing a ticket for a contractor who's never seen your codebase — everthing they need should be in the issue body. The key sections:

- **Context** — what part of the system, with specific file paths
- **Acceptance Criteria** — "when X, then Y" format, each independantly testable
- **Implementation Guide** — exact files to create/modify
- **Patterns to Follow** — references to actual files in the codebase
- **Security Considerations** — auth, validation, data exposure
- **Test Requirements** — specific test cases with file paths
- **Out of Scope** — explicit boundaries so it doesnt scope creep

## CLI Reference

```
ocak init [--force] [--no-ai]    Set up pipeline in current project
ocak run [N] [options]            Run the pipeline (N = single-issue mode)
  --watch                         Stream agent activity with color
  --dry-run                       Show plan without executing
  --once                          Process current batch and exit
  --max-parallel N                Limit concurrency (default: 5)
  --poll-interval N               Seconds between polls (default: 60)
  --manual-review                 Create PRs without auto-merge; wait for human review
  --audit                         Run auditor as post-pipeline gate
  --verbose                       Increase log detail
  --quiet                         Suppress non-error output
ocak resume N [--watch]           Resume a failed pipeline from last successful step
  --dry-run                       Show which steps would re-run
  --verbose / --quiet             Control output verbosity
ocak hiz N [--watch]              Fast-mode: implement + parallel review + security, creates PR
  --dry-run                       Show pipeline plan without executing
  --verbose / --quiet             Control output verbosity
ocak status                       Show pipeline state
ocak clean                        Remove stale worktrees
ocak design [description]         Launch interactive issue design session
```

## FAQ

**What's `ocak hiz`?**

Fast mode. Runs implement (sonnet), then reviewer (haiku) and security-reviewer (sonnet) in parallel, and creates a PR without merging. Good for simple issues where you want a quick PR to review yourself. Roughly 5-10x cheaper than the full pipeline.

```bash
ocak hiz 42 --watch
```

**How do I resume a failed pipeline?**

```bash
ocak resume 42 --watch
```

Picks up from the last successful step. State is saved in `logs/pipeline/issue-42-state.json`.

**How much does it cost?**

Depends on the issue. Simple stuff is $2-5, complex issues can be $10-15. The implementer runs on opus which is the expensive part, reviews on sonnet are pretty cheap. You can see costs in the `--watch` output.

**Is it safe?**

Reasonably. Review agents are read-only (no Write/Edit tools), merging is sequential so you don't get conflicts, and failed piplines get labeled and logged. You can always `--dry-run` first to see what it would do.

**What if it breaks?**

Issues get labeled `pipeline-failed` with a comment explaining what went wrong. Worktrees get cleaned up automatically. Run `ocak clean` to remove any stragglers, and check `logs/pipeline/` for detailed logs.

**Can I run one issue manually?**

```bash
ocak run 42 --watch
```

Runs the full pipeline for issue #42 in your current checkout (no worktree).

**How do I pause it?**

Press `Ctrl+C`. The first signal lets the current agent step finish, then stops the pipeline, commits any in-progress work with a `wip:` prefix, resets issue labels to `auto-ready`, and prints resume commands. A second `Ctrl+C` immediately kills active subprocesses and performs the same cleanup. Exit code is 130.

```bash
ocak resume 42 --watch  # pick up from where it stopped
```

**What languages does it support?**

`ocak init` auto-detects Ruby, TypeScript/JavaScript, Python, Rust, Go, Java, and Elixir. Agents get generated with stack-specific instructions. For anything else you get generic agents that you can customize.

## Development

```bash
git clone https://github.com/clayharmon/ocak
cd ocak
bundle install
bundle exec rspec
bundle exec rubocop
```

## Contributing

Bug reports and pull requests welcome on GitHub.

## License

MIT. See [LICENSE.txt](LICENSE.txt).

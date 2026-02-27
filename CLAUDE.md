# Ocak

A Ruby gem that sets up and runs a multi-agent pipeline for autonomous GitHub issue processing using Claude Code.

## Architecture

```
lib/ocak/
├── cli.rb                 # dry-cli registry, maps subcommands to command classes
├── commands/              # One class per CLI subcommand (init, run, resume, hiz, design, audit, debt, status, clean)
├── config.rb              # Loads and validates ocak.yml, provides typed accessors
├── stack_detector.rb      # Detects project language, framework, test/lint/security tools via data-driven rules
├── monorepo_detector.rb   # MonorepoDetector module (included by StackDetector) — npm/pnpm/cargo/go workspace detection
├── agent_generator.rb     # Generates agent/skill/hook files from ERB templates, optionally enhanced via claude -p
├── pipeline_runner.rb     # Orchestration: poll → plan → worktree → delegate to executor → merge
├── pipeline_executor.rb   # Step execution: run_pipeline, execute_step, conditions, cost tracking
├── claude_runner.rb       # Wraps `claude -p` with stream-json parsing (StreamParser, AgentResult)
├── issue_fetcher.rb       # GitHub CLI wrapper for issue listing, labeling, commenting
├── worktree_manager.rb    # Git worktree create/remove/list/clean
├── merge_manager.rb       # Sequential rebase + test + push, then delegates to merger agent
├── planner.rb             # Batch planning: groups issues for parallel/sequential execution
├── pipeline_state.rb      # Persists per-issue pipeline progress for resume support
├── verification.rb        # Final verification checks (tests + scoped lint) extracted module
├── process_runner.rb      # Subprocess runner with streaming line output and timeout support
├── stream_parser.rb       # Parses NDJSON from `claude --output-format stream-json`
└── logger.rb              # PipelineLogger (file + terminal) and WatchFormatter (colored real-time output)

lib/ocak/templates/
├── agents/*.md.erb        # ERB templates for 8 pipeline agents
├── skills/*/SKILL.md.erb  # ERB templates for 4 interactive skills
├── hooks/*.sh.erb         # ERB templates for lint and test hooks
├── ocak.yml.erb           # Config file template
└── gitignore_additions.txt
```

## Conventions

- **Ruby 3.3**, frozen string literals everywhere
- **dry-cli** for CLI routing — each command is a class inheriting `Dry::CLI::Command`
- **No heavy dependencies** — stdlib only (open3, json, yaml, erb, fileutils, logger, securerandom) plus dry-cli
- **ERB templates** use `trim_mode: "-"` for clean output
- **Config** is always loaded from `ocak.yml` in the project root via `Config.load`
- Agent names use hyphens in filenames (`security-reviewer.md`) but underscores in Ruby (`security_reviewer`)
- All external commands (git, gh, claude) go through `Open3.capture3` or `Open3.popen3`

## Key Patterns

### Agent Invocation
Agents are invoked via `claude -p --verbose --output-format stream-json --allowedTools <tools> -- <prompt>`. The prompt is the agent markdown file contents + a task-specific suffix.

### Pipeline Steps
Each step in `ocak.yml` has an `agent`, `role`, and optional `condition`. Conditions (`has_findings`, `had_fixes`) control whether conditional steps run based on previous agent output containing 🔴 findings.

### Worktree Isolation
Parallel issues get separate git worktrees under `.claude/worktrees/`. After all pipeline steps complete, worktrees are rebased onto main, tested, pushed, and the merger agent creates+merges the PR.

## Development

```bash
bundle exec rspec          # Run tests
bundle exec rubocop        # Run linter
bundle exec rake           # Both
```

## Test Conventions

- RSpec with `verify_partial_doubles`
- Mock external commands (Open3, git, gh, claude) — never shell out in tests
- Use `Dir.mktmpdir` for filesystem tests, clean up in `after` blocks
- Specs mirror `lib/` structure: `spec/ocak/config_spec.rb` tests `lib/ocak/config.rb`

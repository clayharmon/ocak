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
├── batch_processing.rb    # BatchProcessing module (included by PipelineRunner) — process_issues, run_batch, process_one_issue, build_issue_result
├── instance_builders.rb   # InstanceBuilders module (included by PipelineRunner) — factory methods for logger, claude, merge manager; setup helpers
├── shutdown_handling.rb   # ShutdownHandling module (included by PipelineRunner) — graceful/force shutdown, interrupt/error handling, summary
├── merge_orchestration.rb # MergeOrchestration module (included by PipelineRunner) — PR creation, audit blocking, manual review, label transitions
├── failure_reporting.rb   # FailureReporting module — shared label transition + failure comment posting; included by PipelineRunner and Commands::Resume
├── pipeline_executor.rb   # Orchestrates pipeline step execution; includes ParallelExecution, StateManagement, StepExecution, Verification, Planner, StepComments
├── parallel_execution.rb  # ParallelExecution module (included by PipelineExecutor) — collect_parallel_group, run_parallel_group, sync
├── state_management.rb    # StateManagement module (included by PipelineExecutor) — accumulate_state, save_step_progress, write_step_output, check_step_failure, check_cost_budget, update_pipeline_state, log_cost_summary, save_report
├── step_execution.rb      # StepExecution module (included by PipelineExecutor) — run_single_step, handle_already_completed, record_skipped_step, execute_step, skip_reason
├── step_comments.rb       # StepComments module — shared post_step_comment / post_step_completion_comment; included by Hiz and PipelineExecutor
├── claude_runner.rb       # Wraps `claude -p` with stream-json parsing (StreamParser, AgentResult)
├── issue_fetcher.rb       # GitHub CLI wrapper for all issue data access — listing, labeling, commenting, label creation, view
├── worktree_manager.rb    # Git worktree create/remove/list/clean
├── merge_manager.rb       # Sequential rebase + test + push, then delegates to merger agent
├── git_utils.rb           # Shared git helpers — commit_changes (porcelain check → add -A → commit with exit-status checks), safe_branch_name? (validates branch names against flag injection and .. traversal)
├── planner.rb             # Batch planning: groups issues for parallel/sequential execution
├── pipeline_state.rb      # Persists per-issue pipeline progress for resume support
├── run_report.rb          # Writes per-run JSON reports to .ocak/reports/; RunReport#record_step, #finish, #save, .load_all
├── verification.rb        # Final verification checks (tests + scoped lint) extracted module
├── process_runner.rb      # Subprocess runner with streaming line output and timeout support
├── process_registry.rb    # Thread-safe PID registry for subprocess tracking during shutdown
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
- Agent names use hyphens in filenames (`security-reviewer.md`) and in `ocak.yml` step definitions (`security-reviewer`); Ruby identifiers use underscores. `pipeline_executor.rb` converts underscores to hyphens for backwards compatibility with existing user configs.
- All external commands (git, gh, claude) go through `Open3.capture3` or `Open3.popen3`

## Key Patterns

### Agent Invocation
Agents are invoked via `claude -p --verbose --output-format stream-json --allowedTools <tools> -- <prompt>`. The prompt is the agent markdown file contents + a task-specific suffix.

### Pipeline Steps
Each step in `ocak.yml` has an `agent`, `role`, and optional `condition`. Conditions (`has_findings`, `had_fixes`) control whether conditional steps run based on previous agent output containing 🔴 findings.

### Worktree Isolation
Parallel issues get separate git worktrees under `.claude/worktrees/`. After all pipeline steps complete, worktrees are rebased onto main, tested, pushed, and the merger agent creates+merges the PR.

### Issue Data Access
All GitHub issue data fetching goes through `IssueFetcher#view`. Classes that need issue data receive an `IssueFetcher` instance via constructor injection (`issues:` keyword param) rather than calling `gh` directly.

### Pipeline Comments
Both `pipeline_executor.rb` and `hiz.rb` post GitHub comments at pipeline start, per-step completion, skip events, retry warnings, and pipeline summary. Shared comment helpers live in the `StepComments` module (`step_comments.rb`); in `hiz.rb` they are overridden to accept a `state:` keyword param (`HizState` struct) and access `IssueFetcher` via `state.issues`. Always use `post_step_comment` (wraps `issues&.comment` with `rescue StandardError => nil`) so comment failures never crash the pipeline. Emoji vocabulary: 🚀 start, 🔄 in-progress, ✅ success, ❌ failure, ⏭️ skip, ⚠️ warning.

### Prompt Injection Protection
All externally-sourced content embedded in agent prompts must be wrapped in XML delimiter tags. This prevents malicious content (e.g., a PR comment saying "IGNORE PREVIOUS INSTRUCTIONS...") from being interpreted as instructions by the agent. Examples: `<issue_body>`, `<review_output>`, `<review_comments>`, `<pr_comments>`. See `planner.rb#build_step_prompt` and `reready_processor.rb#build_feedback_prompt`.

### Two-Tiered Shutdown
`PipelineRunner` implements two-tiered signal handling via `shutdown!`:
- **Tier 1 (first Ctrl+C):** Sets `@shutting_down` flag. Current agent step finishes naturally, then the pipeline stops. Uncommitted worktree changes are committed with a `wip:` message, issue labels are reset to `:label_ready`, a ⚠️ comment is posted with the resume command, and a summary is printed to stderr. Exit code 130.
- **Tier 2 (second Ctrl+C):** Calls `ProcessRegistry#kill_all` to SIGTERM→wait→SIGKILL all tracked subprocesses, then performs the same cleanup as tier 1. Exit code 130.
- `ProcessRegistry` is a thread-safe PID set (`Mutex` + `Set`). `ProcessRunner#run` registers PIDs after `popen3` spawn and unregisters in `ensure`. `ClaudeRunner` passes the registry through to `ProcessRunner`.
- `PipelineExecutor` accepts a `shutdown_check:` callable and checks it between steps; if true, it sets `state[:interrupted]` and breaks out of the step loop without deleting `PipelineState`.

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

# frozen_string_literal: true

require 'open3'
require 'shellwords'

module Ocak
  # Final verification checks (tests + lint) extracted from PipelineRunner.
  module Verification
    def run_verification_with_retry(logger:, claude:, chdir:, model: nil, &post_comment)
      return nil unless @config.test_command || @config.lint_check_command

      logger.info('--- Final verification ---')
      post_comment&.call("\u{1F504} **Phase: final-verify** (verification)")
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = run_final_checks(logger, chdir: chdir)

      unless result[:success]
        logger.warn('Final checks failed, attempting fix...')
        post_comment&.call("\u{26A0}\u{FE0F} **Final verification failed** \u2014 attempting auto-fix...")
        fix_prompt = "Fix these test/lint failures:\n\n" \
                     "<verification_output>\n#{result[:output]}\n</verification_output>"
        fix_opts = { chdir: chdir }
        fix_opts[:model] = model if model
        claude.run_agent('implementer', fix_prompt, **fix_opts)
        result = run_final_checks(logger, chdir: chdir)
      end

      duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time).round
      if result[:success]
        post_comment&.call("\u{2705} **Phase: final-verify** completed \u2014 #{duration}s")
        nil
      else
        post_comment&.call("\u{274C} **Phase: final-verify** failed \u2014 #{duration}s")
        { success: false, phase: 'final-verify', output: result[:output] }
      end
    end

    def run_final_checks(logger, chdir:)
      failures = []
      output_parts = []

      check_tests(failures, output_parts, logger, chdir: chdir)
      check_lint(failures, output_parts, logger, chdir: chdir)

      if failures.empty?
        logger.info('All checks passed')
        { success: true }
      else
        logger.warn("Checks failed: #{failures.join(', ')}")
        { success: false, failures: failures, output: output_parts.join("\n\n") }
      end
    end

    def run_scoped_lint(logger, chdir:)
      changed_stdout, = Open3.capture3('git', 'diff', '--name-only', 'main', chdir: chdir)
      changed_files = changed_stdout.lines.map(&:strip).reject(&:empty?)

      extensions = lint_extensions_for(@config.language)
      lintable = changed_files.select { |f| extensions.any? { |ext| f.end_with?(ext) } }

      if lintable.empty?
        logger.info('No changed files to lint')
        return nil
      end

      cmd_parts = Shellwords.shellsplit(@config.lint_check_command)
      cmd_parts << '--force-exclusion' if @config.lint_check_command.include?('rubocop')
      cmd_parts.concat(lintable)

      stdout, stderr, status = Open3.capture3(*cmd_parts, chdir: chdir)
      return nil if status.success?

      "=== #{@config.lint_check_command} (#{lintable.size} files) ===\n#{stdout}\n#{stderr}"
    rescue ArgumentError => e
      logger&.warn("Invalid shell command in config: #{@config.lint_check_command.inspect} (#{e.message})")
      "=== #{@config.lint_check_command} ===\nArgumentError: #{e.message}"
    end

    def lint_extensions_for(language)
      case language
      when 'ruby'                    then %w[.rb .rake .gemspec]
      when 'typescript'              then %w[.ts .tsx]
      when 'javascript'              then %w[.js .jsx]
      when 'python'                  then %w[.py]
      when 'rust'                    then %w[.rs]
      when 'go'                      then %w[.go]
      when 'elixir'                  then %w[.ex .exs]
      when 'java'                    then %w[.java]
      else                                %w[.rb .ts .tsx .js .jsx .py .rs .go]
      end
    end

    private

    def check_tests(failures, output_parts, logger, chdir:)
      return unless @config.test_command

      stdout, stderr, status = Open3.capture3(*Shellwords.shellsplit(@config.test_command), chdir: chdir)
      return if status.success?

      failures << @config.test_command
      output_parts << "=== #{@config.test_command} ===\n#{stdout}\n#{stderr}"
    rescue ArgumentError => e
      logger&.warn("Invalid shell command in config: #{@config.test_command.inspect} (#{e.message})")
      failures << @config.test_command
    end

    def check_lint(failures, output_parts, logger, chdir:)
      return unless @config.lint_check_command

      lint_output = run_scoped_lint(logger, chdir: chdir)
      return unless lint_output

      failures << @config.lint_check_command
      output_parts << lint_output
    end
  end
end

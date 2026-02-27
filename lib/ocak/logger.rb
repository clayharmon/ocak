# frozen_string_literal: true

require 'logger'
require 'fileutils'

module Ocak
  class PipelineLogger
    COLORS = {
      reset: "\e[0m",
      bold: "\e[1m",
      dim: "\e[2m",
      red: "\e[31m",
      green: "\e[32m",
      yellow: "\e[33m",
      blue: "\e[34m",
      magenta: "\e[35m",
      cyan: "\e[36m",
      white: "\e[37m"
    }.freeze

    AGENT_COLORS = {
      'implementer' => :cyan,
      'reviewer' => :magenta,
      'security-reviewer' => :red,
      'auditor' => :yellow,
      'documenter' => :blue,
      'merger' => :green,
      'planner' => :white,
      'pipeline' => :cyan
    }.freeze

    def initialize(log_dir: nil, issue_number: nil, color: $stderr.tty?)
      @color = color
      @mutex = Mutex.new
      @file_logger = setup_file_logger(log_dir, issue_number) if log_dir
    end

    def info(msg, agent: nil)
      log(:info, msg, agent: agent)
    end

    def warn(msg, agent: nil)
      log(:warn, msg, agent: agent, color: :yellow)
    end

    def error(msg, agent: nil)
      log(:error, msg, agent: agent, color: :red)
    end

    def debug(msg, agent: nil) # rubocop:disable Lint/UnusedMethodArgument
      @file_logger&.debug(msg)
    end

    attr_reader :log_file_path

    private

    def log(level, msg, agent: nil, color: nil)
      ts = Time.now.strftime('%Y-%m-%d %H:%M:%S')
      plain = "[#{ts}] #{level.to_s.upcase}: #{msg}"

      @file_logger&.send(level, msg)

      @mutex.synchronize do
        output = @color ? colorize(ts, level, msg, agent: agent, color: color) : plain
        $stderr.write("#{output}\n")
      end
    end

    def colorize(timestamp, level, msg, agent: nil, color: nil)
      parts = [c(:dim), timestamp, c(:reset), ' ']

      if agent
        agent_color = AGENT_COLORS.fetch(agent, :white)
        parts.push c(agent_color), c(:bold), "[#{agent}]", c(:reset), ' '
      end

      msg_color = color || level_color(level)
      parts.push c(msg_color), msg, c(:reset)
      parts.join
    end

    def level_color(level)
      case level
      when :error then :red
      when :warn  then :yellow
      when :info  then :white
      else :dim
      end
    end

    def c(name)
      @color ? COLORS.fetch(name, '') : ''
    end

    def setup_file_logger(log_dir, issue_number)
      FileUtils.mkdir_p(log_dir)
      timestamp = Time.now.strftime('%Y%m%d-%H%M%S')
      suffix = issue_number ? "issue-#{issue_number}" : 'pipeline'
      @log_file_path = File.join(log_dir, "#{timestamp}-#{suffix}.log")

      logger = ::Logger.new(@log_file_path)
      logger.formatter = proc do |severity, datetime, _progname, msg|
        "[#{datetime.strftime('%Y-%m-%d %H:%M:%S')}] #{severity}: #{msg}\n"
      end
      logger
    end
  end

  # Colorized real-time terminal output for --watch mode.
  class WatchFormatter
    def initialize(io = $stderr)
      @io = io
      @tty = io.respond_to?(:tty?) && io.tty?
      @mutex = Mutex.new
    end

    def emit(agent_name, event)
      return unless event

      line = format_event(agent_name, event)
      return unless line

      @mutex.synchronize { @io.puts line }
    end

    private

    def format_event(agent_name, event)
      ts = Time.now.strftime('%H:%M:%S')
      agent_color = PipelineLogger::AGENT_COLORS.fetch(agent_name, :white)
      prefix = "#{c(:dim)}#{ts}#{c(:reset)} #{c(agent_color)}#{c(:bold)}[#{agent_name}]#{c(:reset)}"

      case event[:category]
      when :init       then "#{prefix} #{c(:dim)}Session started (model: #{event[:model]})#{c(:reset)}"
      when :tool_call  then format_tool_call(prefix, event)
      when :tool_result then format_tool_result(prefix, event)
      when :text       then format_text(prefix, event)
      when :result     then format_result(prefix, event)
      end
    end

    def format_tool_call(prefix, event)
      case event[:tool]
      when 'Edit', 'Write'
        "#{prefix} #{c(:yellow)}[EDIT]#{c(:reset)} #{event[:detail]}"
      when 'Bash'
        "#{prefix} #{c(:blue)}[BASH]#{c(:reset)} #{c(:dim)}#{event[:detail]}#{c(:reset)}"
      when 'Read'
        "#{prefix} #{c(:dim)}[READ] #{event[:detail]}#{c(:reset)}"
      when 'Glob', 'Grep'
        "#{prefix} #{c(:dim)}[#{event[:tool].upcase}] #{event[:detail]}#{c(:reset)}"
      else
        "#{prefix} #{c(:dim)}[#{event[:tool]}]#{c(:reset)}"
      end
    end

    def format_tool_result(prefix, event)
      return nil unless event[:is_test_result]

      color = event[:passed] ? :green : :red
      status = event[:passed] ? 'PASS' : 'FAIL'
      "#{prefix} #{c(color)}#{c(:bold)}[TEST #{status}]#{c(:reset)} #{c(:dim)}#{event[:command]}#{c(:reset)}"
    end

    def format_text(prefix, event)
      return nil unless event[:has_findings]

      if event[:has_red]
        "#{prefix} #{c(:red)}#{c(:bold)}[REVIEW] BLOCKING#{c(:reset)}"
      elsif event[:has_yellow]
        "#{prefix} #{c(:yellow)}[REVIEW] WARNING#{c(:reset)}"
      else
        "#{prefix} #{c(:green)}[REVIEW] PASS#{c(:reset)}"
      end
    end

    def format_result(prefix, event)
      cost = event[:cost_usd] ? format('$%.4f', event[:cost_usd]) : 'n/a'
      dur = event[:duration_ms] ? "#{(event[:duration_ms] / 1000.0).round(1)}s" : 'n/a'
      turns = event[:num_turns] ? "#{event[:num_turns]} turns" : ''
      color = event[:subtype] == 'success' ? :green : :red
      done = "#{c(color)}#{c(:bold)}[DONE]#{c(:reset)}"
      detail = "#{c(:dim)}#{event[:subtype]} #{cost} #{dur} #{turns}#{c(:reset)}"
      "#{prefix} #{done} #{detail}"
    end

    def c(name)
      @tty ? PipelineLogger::COLORS.fetch(name, '') : ''
    end
  end
end

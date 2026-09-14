# frozen_string_literal: true

require "optparse"

require_relative "change_set"
require_relative "configuration"
require_relative "doctor"
require_relative "reporter"
require_relative "validator"

module AIWorkflow
  class Runner
    HELP = <<~TEXT
      Usage:
        ./Scripts/ai-workflow doctor
        ./Scripts/ai-workflow validate --route quick|standard|spec [options]

      Validate options:
        --route ROUTE             Required route
        --harness-evidence TEXT   Focused validation result that actually ran
        --reviewed-by NAME        Completed read-only reviewer; repeatable
        --openspec-change NAME    Approved OpenSpec change for Spec work
        --skip-commands           Mark configured project commands UNVERIFIED

      Exit codes:
        0 PASS, 1 deterministic FAIL, 2 invalid use/configuration,
        3 required UNVERIFIED evidence, 4 missing required environment.
    TEXT

    def initialize(root: nil, output: $stdout, error: $stderr)
      @root = root
      @output = output
      @error = error
    end

    def run(arguments)
      arguments = arguments.dup
      command = arguments.shift
      return show_help(0) if %w[-h --help help].include?(command)
      return invalid("Expected doctor or validate") unless %w[doctor validate].include?(command)

      root = @root || git_root
      configuration = Configuration.new(root)
      reporter = Reporter.new(output: @output)
      if command == "doctor"
        return invalid("doctor accepts no arguments") unless arguments.empty?
        Doctor.new(configuration, reporter).run
      else
        options = parse_validate(arguments)
        return 0 if options == :help
        Validator.new(configuration, reporter, change_set: ChangeSet.new(root), options: options).run
      end
    rescue ConfigurationError, OptionParser::ParseError => e
      invalid(e.message)
    rescue GitError => e
      invalid("Git error: #{e.message}")
    end

    private

    def parse_validate(arguments)
      options = { reviewed_by: [], skip_commands: false }
      parser = OptionParser.new do |opts|
        opts.on("--route ROUTE") { |value| options[:route] = value.downcase }
        opts.on("--harness-evidence TEXT") { |value| options[:harness_evidence] = value }
        opts.on("--reviewed-by NAME") { |value| options[:reviewed_by] << value }
        opts.on("--openspec-change NAME") { |value| options[:openspec_change] = value }
        opts.on("--skip-commands") { options[:skip_commands] = true }
        opts.on("--help") do
          @output.puts HELP
          return :help
        end
      end
      parser.parse!(arguments)
      raise OptionParser::InvalidArgument, "Unexpected arguments: #{arguments.join(' ')}" unless arguments.empty?
      raise OptionParser::MissingArgument, "--route" unless options[:route]
      unless Configuration::ROUTES.include?(options[:route])
        raise OptionParser::InvalidArgument, "route must be quick, standard, or spec"
      end
      options
    end

    def git_root
      root = `git rev-parse --show-toplevel 2>/dev/null`.strip
      raise GitError, "Not inside a Git repository" if root.empty?
      root
    end

    def invalid(message)
      @error.puts "ERROR: #{message}"
      @error.puts HELP
      2
    end

    def show_help(code)
      @output.puts HELP
      code
    end
  end
end

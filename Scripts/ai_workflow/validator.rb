# frozen_string_literal: true

require "fileutils"
require "open3"
require "shellwords"

module AIWorkflow
  class Validator
    SOURCE_EXTENSIONS = %w[.swift .m .mm .h .c .cc .cpp .java .kt .js .jsx .ts .tsx .py .rb .go .rs].freeze
    WORKFLOW_SOURCE_PREFIXES = %w[.codex/hooks/ Scripts/ai_workflow/ Scripts/ai_workflow_tests/].freeze
    WORKFLOW_SOURCE_PATHS = %w[Scripts/ai_workflow_test.rb].freeze
    DEBUG_PATTERN = /\b(?:print|debugPrint|NSLog|console\.log|puts)\s*(?:\(|\s)|^\s*(?:debugger|binding\.pry)\b/
    SECRET_PATTERN = %r{-----BEGIN\s+(?:RSA\s+|EC\s+|OPENSSH\s+)?PRIVATE\s+KEY-----|\bAKIA[0-9A-Z]{16}\b|\b(?:sk|ghp|github_pat)-?[A-Za-z0-9_\-]{20,}\b|\bBearer\s+[A-Za-z0-9._~+/=-]{20,}\b}i
    CONFLICT_PATTERN = /^(?:<{7}|={7}|>{7})(?:\s|$)/

    def initialize(configuration, reporter, change_set:, options:, command_runner: nil)
      @configuration = configuration
      @reporter = reporter
      @change_set = change_set
      @options = options
      @command_runner = command_runner || method(:run_command)
    end

    def run
      paths = @change_set.paths
      validate_route(paths)
      scan_added_lines
      validate_generated_files(paths)
      validate_openspec_change
      validate_harness
      validate_reviewers
      validate_project_commands
      @reporter.summary
      @reporter.exit_code
    rescue GitError => e
      @reporter.add("FAIL", "git-change-set", e.message)
      @reporter.summary
      @reporter.exit_code
    end

    private

    def validate_route(paths)
      selected = @options.fetch(:route)
      minimum = @configuration.minimum_route(paths)
      detail = "selected=#{selected}, minimum=#{minimum}, changed_paths=#{paths.length}"
      status = @configuration.route_satisfies?(selected, minimum) ? "PASS" : "FAIL"
      @reporter.add(status, "route", status == "PASS" ? detail : "#{detail}; upgrade the route")
    end

    def scan_added_lines
      lines = @change_set.added_lines
      conflict = lines.select { |_path, line| CONFLICT_PATTERN.match?(line) }
      debug = lines.select do |path, line|
        SOURCE_EXTENSIONS.include?(File.extname(path)) && !workflow_source?(path) &&
          DEBUG_PATTERN.match?(line) && !allowlisted?("debug-code.txt", line)
      end
      secrets = lines.select { |_path, line| SECRET_PATTERN.match?(line) && !allowlisted?("secret-scan.txt", line) }
      report_hits("conflict-markers", conflict)
      report_hits("debug-code", debug)
      report_hits("secret-scan", secrets)
    end

    def workflow_source?(path)
      WORKFLOW_SOURCE_PATHS.include?(path) || WORKFLOW_SOURCE_PREFIXES.any? { |prefix| path.start_with?(prefix) }
    end

    def report_hits(name, hits)
      if hits.empty?
        @reporter.add("PASS", name, "No blocked content in added lines")
      else
        @reporter.add("FAIL", name, "#{hits.length} added line(s) in #{hits.first(5).map(&:first).uniq.join(', ')}")
      end
    end

    def allowlisted?(filename, line)
      @allowlists ||= {}
      @allowlists[filename] ||= begin
        path = File.join(@configuration.root, ".ai-workflow/allowlists", filename)
        if File.file?(path)
          File.readlines(path, chomp: true).each_with_object([]) do |source, patterns|
            stripped = source.strip
            patterns << Regexp.new(stripped) unless stripped.empty? || stripped.start_with?("#")
          end
        else
          []
        end
      end
      @allowlists[filename].any? { |pattern| pattern.match?(line) }
    rescue RegexpError => e
      raise ConfigurationError, "Invalid #{filename}: #{e.message}"
    end

    def validate_generated_files(paths)
      relevant = false
      @configuration.generated_files.each do |entry|
        output = entry.fetch("output")
        sources = Array(entry.fetch("sources"))
        output_changed = paths.include?(output)
        source_changed = !(paths & sources).empty?
        relevant ||= output_changed || source_changed
        @reporter.add("FAIL", "generated-files", "#{output} changed without a registered source") if output_changed && !source_changed
        next unless source_changed
        if entry["verify"].to_s.strip.empty?
          @reporter.add("UNVERIFIED", "generated-verify", "No verify command for #{output}")
        else
          success, detail, environment_missing = @command_runner.call(entry.fetch("verify"), "generated-verify")
          @reporter.add(environment_missing ? "UNVERIFIED" : (success ? "PASS" : "FAIL"), environment_missing ? "environment" : "generated-verify", detail)
        end
      end
      @reporter.add("SKIP", "generated-files", "No registered generated/source paths changed") unless relevant
    end

    def validate_harness
      if @options[:route] == "quick"
        @reporter.add("SKIP", "harness-evidence", "Quick uses static/document inspection")
      elsif @options[:harness_evidence].to_s.strip.empty?
        @reporter.add("UNVERIFIED", "harness-evidence", "Supply --harness-evidence with the final focused result")
      else
        @reporter.add("PASS", "harness-evidence", @options[:harness_evidence].strip)
      end
    end

    def validate_openspec_change
      unless @options[:route] == "spec"
        @reporter.add("SKIP", "openspec-change", "Required only for Spec")
        return
      end

      name = @options[:openspec_change].to_s.strip
      if name.empty?
        @reporter.add("UNVERIFIED", "openspec-change", "Supply --openspec-change NAME for the approved Spec change")
        return
      end
      unless name.match?(/\A[a-z0-9][a-z0-9-]*\z/)
        @reporter.add("FAIL", "openspec-change", "Invalid change name: #{name}")
        return
      end

      base = File.join(@configuration.root, "openspec", "changes", name)
      required = %w[proposal.md design.md tasks.md].map { |file| File.join(base, file) }
      missing = required.reject { |path| nonempty_file?(path) }
      specs = Dir.glob(File.join(base, "specs", "**", "*.md")).select { |path| nonempty_file?(path) }
      missing << File.join(base, "specs/**/*.md") if specs.empty?
      if missing.empty?
        @reporter.add("PASS", "openspec-change", "#{name}: non-empty proposal, specs, design, and tasks present")
      else
        relative = missing.map { |path| path.delete_prefix("#{@configuration.root}/") }
        @reporter.add("FAIL", "openspec-change", "Missing or empty: #{relative.join(', ')}")
        return
      end

      success, detail, environment_missing = @command_runner.call("openspec validate #{name}", "openspec-validate")
      status = environment_missing ? "UNVERIFIED" : (success ? "PASS" : "FAIL")
      @reporter.add(status, environment_missing ? "environment" : "openspec-validation", detail)
    end

    def nonempty_file?(path)
      File.file?(path) && !File.read(path).strip.empty?
    rescue Errno::EACCES, Errno::ENOENT
      false
    end

    def validate_reviewers
      required = @configuration.reviewers(@options[:route])
      if required.empty?
        @reporter.add("SKIP", "reviewers", "No reviewer required")
        return
      end
      missing = required - @options.fetch(:reviewed_by)
      @reporter.add(missing.empty? ? "PASS" : "UNVERIFIED", "reviewers", missing.empty? ? "Acknowledged: #{required.join(', ')}" : "Missing read-only pass: #{missing.join(', ')}")
    end

    def validate_project_commands
      commands = @configuration.validation_commands(@options[:route])
      if @options[:route] == "quick"
        @reporter.add("SKIP", "project-validation", "Quick route runs no project commands")
        return
      end
      required_groups = ["standard"]
      required_groups << "spec" if @options[:route] == "spec"
      missing_groups = required_groups.select { |route| @configuration.configured_commands(route).empty? }
      unless missing_groups.empty?
        @reporter.add("UNVERIFIED", "project-validation", "No #{missing_groups.join(' or ')} validation commands configured")
      end
      return if commands.empty?
      if @options[:skip_commands]
        @reporter.add("UNVERIFIED", "project-validation", "Configured commands explicitly skipped")
        return
      end
      if @reporter.results.any? { |result| result.status == "FAIL" }
        @reporter.add("SKIP", "project-validation", "Earlier deterministic gate failed")
        return
      end
      commands.each_with_index do |command, index|
        success, detail, environment_missing = @command_runner.call(command, "project-#{index + 1}")
        @reporter.add(environment_missing ? "UNVERIFIED" : (success ? "PASS" : "FAIL"), environment_missing ? "environment" : "project-validation", detail)
      end
    end

    def run_command(command_text, label)
      command = Shellwords.split(command_text)
      return [false, "Empty command for #{label}", false] if command.empty?
      unless executable?(command.first)
        return [false, "Required command unavailable: #{command.first}", true]
      end
      log_dir = File.join(@configuration.root, ".ai-workflow/logs")
      FileUtils.mkdir_p(log_dir)
      log_path = File.join(log_dir, "#{label}.log")
      tail = []
      status = nil
      File.open(log_path, "w") do |log|
        Open3.popen2e(*command, chdir: @configuration.root) do |stdin, output, wait|
          stdin.close
          output.each_line do |line|
            log.write(line)
            tail << line.strip
            tail.shift while tail.length > 20
          end
          status = wait.value
        end
      end
      detail = "#{command_text}; log=#{log_path.delete_prefix("#{@configuration.root}/")}" 
      detail += "; tail=#{tail.reject(&:empty?).last}" unless status.success?
      [status.success?, detail, false]
    rescue ArgumentError => e
      [false, "Invalid command #{command_text.inspect}: #{e.message}", false]
    end

    def executable?(command)
      if command.include?(File::SEPARATOR)
        File.executable?(File.expand_path(command, @configuration.root))
      else
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
          File.executable?(File.join(directory, command))
        end
      end
    end
  end
end

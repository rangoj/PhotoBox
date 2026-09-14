# frozen_string_literal: true

require "json"
require "open3"
require "rubygems/version"
require "shellwords"
require "yaml"

module AIWorkflow
  class Doctor
    WORKFLOW_FILES = %w[
      AGENTS.md WORKFLOW.md .ai-workflow/config.yml .ai-workflow/generated-files.yml
      .codex/config.toml .codex/hooks.json .codex/hooks/session_start.rb
      .codex/hooks/protect_generated_files.rb .codex/hooks/stop_reminder.rb
      .codex/agents/reviewer.toml .codex/agents/test-reviewer.toml
      Scripts/ai-workflow Scripts/ai_workflow/runner.rb
      Scripts/ai_workflow/configuration.rb Scripts/ai_workflow/change_set.rb
      Scripts/ai_workflow/reporter.rb Scripts/ai_workflow/doctor.rb
      Scripts/ai_workflow/validator.rb Scripts/ai_workflow_test.rb
    ].freeze

    def initialize(configuration, reporter, finder: nil, capture: nil, skill_finder: nil)
      @configuration = configuration
      @reporter = reporter
      @finder = finder || method(:find_executable)
      @capture = capture || method(:capture_command)
      @skill_finder = skill_finder || method(:find_skill)
    end

    def run
      check_paths
      check_commands
      check_validation_configuration
      check_integrations
      check_hook_runtime
      check_hooks_json
      @reporter.add("WARN", "hook-trust", "Trust the repository, start a new Codex task, then review project Hooks with /hooks")
      @reporter.summary
      @reporter.exit_code
    end

    private

    def root
      @configuration.root
    end

    def check_paths
      missing_workflow = WORKFLOW_FILES.reject { |path| File.file?(File.join(root, path)) }
      if missing_workflow.empty?
        @reporter.add("PASS", "workflow-files", "Required portable workflow files exist")
      else
        @reporter.add("FAIL", "workflow-files", "Missing: #{missing_workflow.join(', ')}")
      end

      missing_project = @configuration.required_paths.reject { |path| File.exist?(File.join(root, path)) }
      if missing_project.empty?
        @reporter.add("PASS", "project-paths", "Configured required paths exist")
      else
        @reporter.add("FAIL", "project-paths", "Missing: #{missing_project.join(', ')}")
      end
    end

    def check_commands
      (@configuration.required_commands + @configuration.optional_commands).uniq.each do |command|
        path = @finder.call(command)
        if path
          @reporter.add("PASS", command, path)
        elsif @configuration.required_commands.include?(command)
          @reporter.add("UNVERIFIED", "environment", "Required command missing: #{command}")
        else
          @reporter.add("WARN", command, "Optional command unavailable")
        end
      end
    end

    def check_validation_configuration
      %w[standard spec].each do |route|
        commands = @configuration.configured_commands(route)
        if commands.empty?
          @reporter.add("UNVERIFIED", "#{route}-commands", "No project validation command configured")
        else
          @reporter.add("PASS", "#{route}-commands", commands.join(" | "))
        end
      end
    end

    def check_integrations
      check_node_version
      check_openspec_cli
      check_openspec
      check_superpowers
    end

    def check_node_version
      return unless @configuration.integration("openspec")["required"]
      node = @finder.call("node")
      unless node
        @reporter.add("UNVERIFIED", "environment", "Required command missing: node")
        return
      end

      stdout, stderr, success = @capture.call([node, "--version"], root)
      version = stdout.to_s.strip.delete_prefix("v")
      if success && Gem::Version.new(version) >= Gem::Version.new("20.19.0")
        @reporter.add("PASS", "node-version", version)
      else
        detail = success ? "OpenSpec needs Node.js 20.19.0+; found #{version}" : stderr.to_s.lines.last.to_s.strip
        @reporter.add("UNVERIFIED", "environment", detail)
      end
    rescue ArgumentError
      @reporter.add("UNVERIFIED", "environment", "Could not parse Node.js version: #{version}")
    end

    def check_openspec_cli
      return unless @configuration.integration("openspec")["required"]
      executable = @finder.call("openspec")
      unless executable
        @reporter.add("UNVERIFIED", "environment", "Required command missing: openspec")
        return
      end

      stdout, stderr, success = @capture.call([executable, "--version"], root)
      raw_version = stdout.to_s.strip
      match = raw_version.match(/\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?/)
      version = match && Gem::Version.new(match[0])
      if success && version && version > Gem::Version.new("0")
        @reporter.add("PASS", "openspec-version", version)
      else
        detail = stderr.to_s.lines.last.to_s.strip
        detail = "openspec --version returned no valid non-zero version: #{raw_version.inspect}" if detail.empty?
        @reporter.add("UNVERIFIED", "openspec-version", detail)
      end
    rescue ArgumentError
      @reporter.add("UNVERIFIED", "openspec-version", "Could not parse OpenSpec version: #{raw_version.inspect}")
    end

    def check_openspec
      config = @configuration.integration("openspec")
      unless config["required"]
        @reporter.add("SKIP", "openspec", "Integration disabled")
        return
      end

      config_path = config.fetch("config_path")
      marker_path = config.fetch("target_marker")
      skills = Array(config["required_skills"]).to_h do |name|
        [name, File.join(config.fetch("skill_root"), name, "SKILL.md")]
      end
      missing = ([config_path, marker_path] + skills.values).reject { |path| File.file?(File.join(root, path)) }
      invalid = []
      invalid << config_path if File.file?(File.join(root, config_path)) && !valid_yaml_mapping?(File.join(root, config_path))
      marker = File.join(root, marker_path)
      invalid << marker_path if File.file?(marker) && File.read(marker).strip != "codex"
      skills.each do |name, path|
        absolute = File.join(root, path)
        invalid << path if File.file?(absolute) && !valid_skill_file?(absolute, name)
      end
      if missing.empty? && invalid.empty?
        @reporter.add("PASS", "openspec", "Project config parses and #{skills.length} core-profile Codex Skills are valid")
      else
        detail = []
        detail << "missing: #{missing.join(', ')}" unless missing.empty?
        detail << "invalid: #{invalid.join(', ')}" unless invalid.empty?
        @reporter.add("UNVERIFIED", "openspec", "#{detail.join('; ')}; run openspec init --tools codex --profile core --no-copilot-cloud")
      end
    end

    def check_superpowers
      config = @configuration.integration("superpowers")
      unless config["required"]
        @reporter.add("SKIP", "superpowers", "Integration disabled")
        return
      end

      name = config.fetch("bootstrap_skill")
      path = @skill_finder.call(name)
      if path && official_superpowers_skill?(path, name)
        @reporter.add("PASS", "superpowers", path)
      else
        @reporter.add("UNVERIFIED", "superpowers", "Missing or invalid official plugin Skill #{name}; install Superpowers from Codex Plugins")
      end
    end

    def check_hook_runtime
      hooks = Dir.glob(File.join(root, ".codex/hooks/*.rb"))
      failures = hooks.reject { |path| @capture.call(["/usr/bin/ruby", "-c", path], root).last }
      if failures.empty?
        @reporter.add("PASS", "hook-runtime", "System Ruby parses all Hooks")
      else
        @reporter.add("FAIL", "hook-runtime", "Invalid: #{failures.map { |path| File.basename(path) }.join(', ')}")
      end
    end

    def check_hooks_json
      JSON.parse(File.read(File.join(root, ".codex/hooks.json")))
      @reporter.add("PASS", "hooks-json", "Valid JSON")
    rescue JSON::ParserError, Errno::ENOENT => e
      @reporter.add("FAIL", "hooks-json", e.message)
    end

    def find_executable(command)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
        path = File.join(directory, command)
        return path if File.file?(path) && File.executable?(path)
      end
      nil
    end

    def capture_command(command, directory)
      stdout, stderr, status = Open3.capture3(*command, chdir: directory)
      [stdout, stderr, status.success?]
    end

    def find_skill(name)
      candidates = Dir.glob(File.join(Dir.home, ".codex", "plugins", "cache", "**", "skills", name, "SKILL.md"))
      candidates.find { |path| File.file?(path) }
    end

    def valid_yaml_mapping?(path)
      value = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
      value.is_a?(Hash) && value["schema"] == "spec-driven"
    rescue Psych::SyntaxError, Errno::EACCES, Errno::ENOENT
      false
    end

    def valid_skill_file?(path, expected_name)
      source = File.read(path)
      match = source.match(/\A---\s*\n(.*?)\n---\s*(?:\n|\z)/m)
      return false unless match

      frontmatter = YAML.safe_load(match[1], permitted_classes: [], aliases: false)
      frontmatter.is_a?(Hash) && frontmatter["name"] == expected_name &&
        !frontmatter["description"].to_s.strip.empty? && !source[match.end(0)..-1].to_s.strip.empty?
    rescue Psych::SyntaxError, Errno::EACCES, Errno::ENOENT
      false
    end

    def official_superpowers_skill?(path, expected_name)
      expanded = File.expand_path(path)
      components = expanded.split(File::SEPARATOR)
      cache_index = components.each_index.find do |index|
        components[index] == "plugins" && components[index + 1] == "cache"
      end
      return false unless cache_index && components.any? { |component| component.downcase == "superpowers" }

      cache_root = File.join(File::SEPARATOR, *components[0..(cache_index + 1)])
      plugin_manifest = find_plugin_manifest(File.dirname(expanded), cache_root)
      valid_skill_file?(expanded, expected_name) && valid_superpowers_manifest?(plugin_manifest)
    end

    def find_plugin_manifest(start, cache_root)
      current = start
      loop do
        candidate = File.join(current, ".codex-plugin", "plugin.json")
        return candidate if File.file?(candidate)
        return nil if current == cache_root || current == File.dirname(current)
        current = File.dirname(current)
      end
    end

    def valid_superpowers_manifest?(path)
      return false unless path
      manifest = JSON.parse(File.read(path))
      manifest.is_a?(Hash) && manifest["name"] == "superpowers"
    rescue JSON::ParserError, Errno::EACCES, Errno::ENOENT
      false
    end
  end
end

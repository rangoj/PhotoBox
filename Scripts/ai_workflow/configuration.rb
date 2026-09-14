# frozen_string_literal: true

require "yaml"

module AIWorkflow
  class ConfigurationError < StandardError; end

  class Configuration
    ROUTES = %w[quick standard spec].freeze
    ROUTE_RANK = ROUTES.each_with_index.to_h.freeze
    attr_reader :root, :data, :generated_files

    def initialize(root)
      @root = File.expand_path(root)
      @data = load_yaml(".ai-workflow/config.yml")
      generated = load_yaml(".ai-workflow/generated-files.yml")
      @generated_files = Array(generated["files"])
      validate!
    end

    def project_name
      data.fetch("project").fetch("name")
    end

    def quick_path?(path)
      quick = data.fetch("routes").fetch("quick")
      Array(quick["allowed_paths"]).include?(path) ||
        Array(quick["allowed_prefixes"]).any? { |prefix| path.start_with?(prefix) }
    end

    def spec_path?(path)
      spec = data.fetch("routes").fetch("spec")
      patterns(spec["path_patterns"]).any? { |pattern| pattern.match?(path) } ||
        patterns(spec["keyword_patterns"]).any? { |pattern| pattern.match?(path) }
    end

    def minimum_route(paths)
      return "quick" if paths.empty? || paths.all? { |path| quick_path?(path) }
      return "spec" if paths.any? { |path| spec_path?(path) }
      "standard"
    end

    def route_satisfies?(selected, minimum)
      ROUTE_RANK.fetch(selected) >= ROUTE_RANK.fetch(minimum)
    end

    def reviewers(route)
      Array(data.fetch("routes").fetch("reviewers")[route])
    end

    def required_commands
      Array(data.fetch("doctor")["required_commands"])
    end

    def optional_commands
      Array(data.fetch("doctor")["optional_commands"])
    end

    def required_paths
      Array(data.fetch("doctor")["required_paths"])
    end

    def validation_commands(route)
      return [] if route == "quick"
      commands = configured_commands("standard")
      commands += configured_commands("spec") if route == "spec"
      commands
    end

    def configured_commands(route)
      Array(data.fetch("validation").fetch("#{route}_commands"))
    end

    def integration(name)
      data.fetch("integrations").fetch(name)
    end

    private

    def load_yaml(relative)
      path = File.join(root, relative)
      raise ConfigurationError, "Missing #{relative}" unless File.file?(path)
      YAML.safe_load(File.read(path), permitted_classes: [], aliases: false) || {}
    rescue Psych::SyntaxError => e
      raise ConfigurationError, "Invalid #{relative}: #{e.message}"
    end

    def patterns(sources)
      Array(sources).map { |source| Regexp.new(source) }
    rescue RegexpError => e
      raise ConfigurationError, "Invalid route pattern: #{e.message}"
    end

    def validate!
      raise ConfigurationError, "config version must be 1" unless data["version"] == 1
      %w[project routes doctor integrations validation].each do |key|
        raise ConfigurationError, "Missing config key: #{key}" unless data[key].is_a?(Hash)
      end
      routes = data.fetch("routes")
      %w[quick spec reviewers].each do |key|
        raise ConfigurationError, "Missing routes.#{key}" unless routes[key].is_a?(Hash)
      end
      %w[standard_commands spec_commands].each do |key|
        raise ConfigurationError, "Missing validation.#{key}" unless data.fetch("validation").key?(key)
      end
      patterns(routes.fetch("spec")["path_patterns"])
      patterns(routes.fetch("spec")["keyword_patterns"])
      %w[openspec superpowers].each do |name|
        raise ConfigurationError, "Missing integrations.#{name}" unless data.fetch("integrations")[name].is_a?(Hash)
      end
      openspec = data.fetch("integrations").fetch("openspec")
      %w[required config_path skill_root target_marker required_skills].each do |key|
        raise ConfigurationError, "Missing integrations.openspec.#{key}" unless openspec.key?(key)
      end
      superpowers = data.fetch("integrations").fetch("superpowers")
      %w[required bootstrap_skill].each do |key|
        raise ConfigurationError, "Missing integrations.superpowers.#{key}" unless superpowers.key?(key)
      end
      generated_files.each do |entry|
        unless entry.is_a?(Hash) && entry["output"] && !Array(entry["sources"]).empty?
          raise ConfigurationError, "Each generated file needs output and sources"
        end
      end
    end
  end
end

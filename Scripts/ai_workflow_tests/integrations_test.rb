# frozen_string_literal: true

require_relative "test_helper"
require_relative "../ai_workflow/doctor"

class IntegrationsTest < Minitest::Test
  include WorkflowTestHelper

  def test_doctor_accepts_initialized_integrations
    with_root do |root|
      config = AIWorkflow::Configuration.new(root)
      openspec = config.integration("openspec")
      FileUtils.mkdir_p(File.dirname(File.join(root, openspec.fetch("config_path"))))
      File.write(File.join(root, openspec.fetch("config_path")), "schema: spec-driven\n")
      marker = File.join(root, openspec.fetch("target_marker"))
      FileUtils.mkdir_p(File.dirname(marker))
      File.write(marker, "codex\n")
      openspec.fetch("required_skills").each do |name|
        path = File.join(root, openspec.fetch("skill_root"), name, "SKILL.md")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "---\nname: #{name}\ndescription: test\n---\n\n# #{name}\n")
      end
      superpowers = File.join(root, ".codex/plugins/cache/superpowers/1/skills/using-superpowers/SKILL.md")
      FileUtils.mkdir_p(File.dirname(superpowers))
      File.write(superpowers, "---\nname: using-superpowers\ndescription: test\n---\n\n# Using Superpowers\n")
      plugin_manifest = File.join(root, ".codex/plugins/cache/superpowers/1/.codex-plugin/plugin.json")
      FileUtils.mkdir_p(File.dirname(plugin_manifest))
      File.write(plugin_manifest, JSON.generate("name" => "superpowers"))

      reporter = AIWorkflow::Reporter.new(output: StringIO.new)
      doctor = AIWorkflow::Doctor.new(
        config, reporter,
        finder: ->(name) { "/usr/bin/#{name}" },
        capture: ->(command, _directory) { [command.first.end_with?("node") ? "v20.19.0\n" : "1.2.3\n", "", true] },
        skill_finder: ->(_name) { superpowers }
      )
      doctor.run
      assert reporter.results.any? { |result| result.name == "openspec" && result.status == "PASS" }
      assert reporter.results.any? { |result| result.name == "superpowers" && result.status == "PASS" }
      assert reporter.results.any? { |result| result.name == "node-version" && result.status == "PASS" }
      assert reporter.results.any? { |result| result.name == "openspec-version" && result.status == "PASS" }
    end
  end

  def test_doctor_marks_missing_integrations_unverified
    with_root do |root|
      reporter = AIWorkflow::Reporter.new(output: StringIO.new)
      doctor = AIWorkflow::Doctor.new(
        AIWorkflow::Configuration.new(root), reporter,
        finder: ->(name) { name == "node" ? "/usr/bin/node" : nil },
        capture: ->(_command, _directory) { ["v20.19.0\n", "", true] },
        skill_finder: ->(_name) { nil }
      )
      doctor.run
      assert reporter.results.any? { |result| result.name == "openspec" && result.status == "UNVERIFIED" }
      assert reporter.results.any? { |result| result.name == "superpowers" && result.status == "UNVERIFIED" }
    end
  end


  def test_doctor_rejects_invalid_integration_files
    with_root do |root|
      config = AIWorkflow::Configuration.new(root)
      openspec = config.integration("openspec")
      config_path = File.join(root, openspec.fetch("config_path"))
      FileUtils.mkdir_p(File.dirname(config_path))
      File.write(config_path, "made_up: true\n")
      marker = File.join(root, openspec.fetch("target_marker"))
      FileUtils.mkdir_p(File.dirname(marker))
      File.write(marker, "claude\n")
      openspec.fetch("required_skills").each do |name|
        path = File.join(root, openspec.fetch("skill_root"), name, "SKILL.md")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "---\nname: #{name}\ndescription: no body\n---\n")
      end
      fake = File.join(root, ".codex/plugins/cache/not-superpowers/1/skills/using-superpowers/SKILL.md")
      FileUtils.mkdir_p(File.dirname(fake))
      File.write(fake, "---\nname: using-superpowers\ndescription: fake\n---\n\n# Fake\n")

      reporter = AIWorkflow::Reporter.new(output: StringIO.new)
      AIWorkflow::Doctor.new(
        config, reporter,
        finder: ->(name) { "/usr/bin/#{name}" },
        capture: ->(command, _directory) { [command.first.end_with?("node") ? "v20.19.0\n" : "0.0.0\n", "", true] },
        skill_finder: ->(_name) { fake }
      ).run
      assert reporter.results.any? { |result| result.name == "openspec" && result.status == "UNVERIFIED" }
      assert reporter.results.any? { |result| result.name == "superpowers" && result.status == "UNVERIFIED" }
      assert reporter.results.any? { |result| result.name == "openspec-version" && result.status == "UNVERIFIED" }
    end
  end

  def test_doctor_rejects_wrong_openspec_target_marker_in_isolation
    with_root do |root|
      config = AIWorkflow::Configuration.new(root)
      openspec = config.integration("openspec")
      config_path = File.join(root, openspec.fetch("config_path"))
      FileUtils.mkdir_p(File.dirname(config_path))
      File.write(config_path, "schema: spec-driven\n")
      marker = File.join(root, openspec.fetch("target_marker"))
      FileUtils.mkdir_p(File.dirname(marker))
      File.write(marker, "claude\n")
      openspec.fetch("required_skills").each do |name|
        path = File.join(root, openspec.fetch("skill_root"), name, "SKILL.md")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "---\nname: #{name}\ndescription: test\n---\n\n# #{name}\n")
      end
      superpowers = File.join(root, ".codex/plugins/cache/superpowers/1/skills/using-superpowers/SKILL.md")
      FileUtils.mkdir_p(File.dirname(superpowers))
      File.write(superpowers, "---\nname: using-superpowers\ndescription: test\n---\n\n# Using Superpowers\n")
      plugin_manifest = File.join(root, ".codex/plugins/cache/superpowers/1/.codex-plugin/plugin.json")
      FileUtils.mkdir_p(File.dirname(plugin_manifest))
      File.write(plugin_manifest, JSON.generate("name" => "superpowers"))

      reporter = AIWorkflow::Reporter.new(output: StringIO.new)
      AIWorkflow::Doctor.new(
        config, reporter,
        finder: ->(name) { "/usr/bin/#{name}" },
        capture: ->(command, _directory) { [command.first.end_with?("node") ? "v20.19.0\n" : "1.2.3\n", "", true] },
        skill_finder: ->(_name) { superpowers }
      ).run
      result = reporter.results.find { |entry| entry.name == "openspec" }
      assert_equal "UNVERIFIED", result.status
      assert_includes result.detail, ".openspec-target"
    end
  end
end

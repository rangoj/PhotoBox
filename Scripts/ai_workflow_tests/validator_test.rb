# frozen_string_literal: true

require_relative "test_helper"
require_relative "../ai_workflow/validator"

class ValidatorTest < Minitest::Test
  include WorkflowTestHelper

  FakeChangeSet = Struct.new(:paths, :added_lines)

  def test_rejects_route_downgrade_and_secret
    with_root do |root|
      output = StringIO.new
      reporter = AIWorkflow::Reporter.new(output: output)
      secret = "AKIA" + "ABCDEFGHIJKLMNOP"
      changes = FakeChangeSet.new(["infra/deploy.yml"], [["infra/deploy.yml", secret]])
      options = { route: "quick", reviewed_by: [], skip_commands: false }
      code = AIWorkflow::Validator.new(
        AIWorkflow::Configuration.new(root), reporter,
        change_set: changes, options: options,
        command_runner: ->(_command, _label) { [true, "ok", false] }
      ).run
      assert_equal 1, code
      assert_includes output.string, "upgrade the route"
      assert_includes output.string, "secret-scan"
    end
  end

  def test_missing_evidence_is_unverified
    with_root do |root|
      reporter = AIWorkflow::Reporter.new(output: StringIO.new)
      changes = FakeChangeSet.new(["src/view.rb"], [])
      options = { route: "standard", reviewed_by: [], skip_commands: true }
      code = AIWorkflow::Validator.new(
        AIWorkflow::Configuration.new(root), reporter,
        change_set: changes, options: options
      ).run
      assert_equal 3, code
    end
  end

  def test_debug_scan_ignores_workflow_runtime_but_not_project_source
    with_root do |root|
      reporter = AIWorkflow::Reporter.new(output: StringIO.new)
      paths = [".codex/hooks/session_start.rb", "Scripts/ai_workflow/reporter.rb", "src/app.rb"]
      lines = paths.map { |path| [path, "puts 'status'"] }
      options = {
        route: "standard", reviewed_by: ["reviewer"], skip_commands: false,
        harness_evidence: "focused check passed"
      }
      code = AIWorkflow::Validator.new(
        AIWorkflow::Configuration.new(root), reporter,
        change_set: FakeChangeSet.new(paths, lines), options: options,
        command_runner: ->(_command, _label) { [true, "ok", false] }
      ).run

      result = reporter.results.find { |item| item.name == "debug-code" }
      assert_equal 1, code
      assert_equal "FAIL", result.status
      assert_includes result.detail, "1 added line(s) in src/app.rb"
      refute_includes result.detail, ".codex/hooks"
      refute_includes result.detail, "Scripts/ai_workflow"
    end
  end

  def test_spec_requires_complete_openspec_change
    with_root do |root|
      reporter = AIWorkflow::Reporter.new(output: StringIO.new)
      changes = FakeChangeSet.new(["infra/deploy.yml"], [])
      options = {
        route: "spec", reviewed_by: %w[reviewer test_reviewer],
        skip_commands: true, harness_evidence: "focused check passed",
        openspec_change: "add-deploy"
      }
      code = AIWorkflow::Validator.new(
        AIWorkflow::Configuration.new(root), reporter,
        change_set: changes, options: options
      ).run
      assert_equal 1, code
      assert reporter.results.any? { |result| result.name == "openspec-change" && result.status == "FAIL" }
    end
  end

  def test_spec_accepts_complete_openspec_change
    with_root do |root|
      base = File.join(root, "openspec/changes/add-deploy")
      FileUtils.mkdir_p(File.join(base, "specs/deploy"))
      %w[proposal.md design.md tasks.md].each { |file| File.write(File.join(base, file), "# #{file}\n") }
      File.write(File.join(base, "specs/deploy/spec.md"), "# Requirement\n")
      reporter = AIWorkflow::Reporter.new(output: StringIO.new)
      changes = FakeChangeSet.new(["infra/deploy.yml"], [])
      options = {
        route: "spec", reviewed_by: %w[reviewer test_reviewer],
        skip_commands: true, harness_evidence: "focused check passed",
        openspec_change: "add-deploy"
      }
      code = AIWorkflow::Validator.new(
        AIWorkflow::Configuration.new(root), reporter,
        change_set: changes, options: options,
        command_runner: lambda do |command, _label|
          assert_equal "openspec validate add-deploy", command
          [true, "OpenSpec change is valid", false]
        end
      ).run
      assert_equal 3, code
      assert reporter.results.any? { |result| result.name == "openspec-change" && result.status == "PASS" }
      assert reporter.results.any? { |result| result.name == "openspec-validation" && result.status == "PASS" }
    end
  end

  def test_spec_rejects_change_when_openspec_cli_validation_fails
    with_root do |root|
      base = File.join(root, "openspec/changes/add-deploy")
      FileUtils.mkdir_p(File.join(base, "specs/deploy"))
      %w[proposal.md design.md tasks.md].each { |file| File.write(File.join(base, file), "# #{file}\n") }
      File.write(File.join(base, "specs/deploy/spec.md"), "# Requirement\n")
      reporter = AIWorkflow::Reporter.new(output: StringIO.new)
      options = {
        route: "spec", reviewed_by: %w[reviewer test_reviewer],
        skip_commands: true, harness_evidence: "focused check passed",
        openspec_change: "add-deploy"
      }
      code = AIWorkflow::Validator.new(
        AIWorkflow::Configuration.new(root), reporter,
        change_set: FakeChangeSet.new(["infra/deploy.yml"], []), options: options,
        command_runner: ->(_command, _label) { [false, "OpenSpec validation failed", false] }
      ).run
      assert_equal 1, code
      assert reporter.results.any? { |result| result.name == "openspec-validation" && result.status == "FAIL" }
    end
  end

  def test_spec_rejects_empty_openspec_artifacts_without_running_cli
    with_root do |root|
      base = File.join(root, "openspec/changes/add-deploy")
      FileUtils.mkdir_p(File.join(base, "specs/deploy"))
      %w[proposal.md design.md tasks.md specs/deploy/spec.md].each do |file|
        FileUtils.mkdir_p(File.dirname(File.join(base, file)))
        File.write(File.join(base, file), "")
      end
      reporter = AIWorkflow::Reporter.new(output: StringIO.new)
      code = AIWorkflow::Validator.new(
        AIWorkflow::Configuration.new(root), reporter,
        change_set: FakeChangeSet.new(["infra/deploy.yml"], []),
        options: {
          route: "spec", reviewed_by: %w[reviewer test_reviewer], skip_commands: true,
          harness_evidence: "focused check passed", openspec_change: "add-deploy"
        },
        command_runner: ->(*) { flunk "CLI must not run for empty artifacts" }
      ).run
      assert_equal 1, code
      assert reporter.results.any? { |result| result.name == "openspec-change" && result.status == "FAIL" }
    end
  end
end

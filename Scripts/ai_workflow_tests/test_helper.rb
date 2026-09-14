# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"
require "yaml"

require_relative "../ai_workflow/configuration"
require_relative "../ai_workflow/reporter"

module WorkflowTestHelper
  def with_root
    Dir.mktmpdir("ai-workflow-test") do |root|
      FileUtils.mkdir_p(File.join(root, ".ai-workflow"))
      File.write(File.join(root, ".ai-workflow/config.yml"), YAML.dump(base_config))
      File.write(File.join(root, ".ai-workflow/generated-files.yml"), YAML.dump("version" => 1, "files" => []))
      yield root
    end
  end

  def base_config
    {
      "version" => 1,
      "project" => { "name" => "Test" },
      "routes" => {
        "quick" => { "allowed_paths" => ["README.md"], "allowed_prefixes" => ["Docs/"] },
        "spec" => { "path_patterns" => ["^infra/"], "keyword_patterns" => ["(?i)auth"] },
        "reviewers" => { "standard" => ["reviewer"], "spec" => ["reviewer", "test_reviewer"] }
      },
      "doctor" => { "required_commands" => ["git"], "optional_commands" => [], "required_paths" => [] },
      "integrations" => {
        "openspec" => {
          "required" => true,
          "config_path" => "openspec/config.yaml",
          "skill_root" => ".agents/skills",
          "target_marker" => ".agents/skills/.openspec-target",
          "required_skills" => ["openspec-propose"]
        },
        "superpowers" => { "required" => true, "bootstrap_skill" => "using-superpowers" }
      },
      "validation" => { "standard_commands" => ["ruby -v"], "spec_commands" => ["git --version"] }
    }
  end
end

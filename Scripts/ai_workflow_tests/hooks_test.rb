# frozen_string_literal: true

require "json"
require "open3"
require_relative "test_helper"

class HooksTest < Minitest::Test
  def test_generated_file_hook_denies_apply_patch
    hook = File.expand_path("../../.codex/hooks/protect_generated_files.rb", __dir__)
    Dir.mktmpdir("hook-test") do |root|
      system("git", "init", "-q", root)
      FileUtils.mkdir_p(File.join(root, ".ai-workflow"))
      registry = { "version" => 1, "files" => [{ "output" => "Generated/value.rb", "sources" => ["schema.yml"] }] }
      File.write(File.join(root, ".ai-workflow/generated-files.yml"), YAML.dump(registry))
      input = JSON.generate("tool_name" => "apply_patch", "tool_input" => { "command" => "*** Update File: Generated/value.rb\n" })
      stdout, _stderr, status = Open3.capture3("/usr/bin/ruby", hook, stdin_data: input, chdir: root)
      assert status.success?
      assert_equal "deny", JSON.parse(stdout).dig("hookSpecificOutput", "permissionDecision")
    end
  end
end

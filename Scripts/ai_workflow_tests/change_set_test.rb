# frozen_string_literal: true

require "open3"
require_relative "test_helper"
require_relative "../ai_workflow/change_set"

class ChangeSetTest < Minitest::Test
  def test_combines_staged_unstaged_and_untracked_with_spaces
    Dir.mktmpdir("change-set") do |root|
      system("git", "init", "-q", root)
      File.write(File.join(root, "staged.txt"), "old\n")
      system("git", "-C", root, "add", "staged.txt")
      system("git", "-C", root, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "base")
      File.write(File.join(root, "staged.txt"), "new\n")
      system("git", "-C", root, "add", "staged.txt")
      File.write(File.join(root, "unstaged file.txt"), "hello\n")

      change_set = AIWorkflow::ChangeSet.new(root)
      assert_equal ["staged.txt", "unstaged file.txt"], change_set.paths
      assert_includes change_set.added_lines, ["unstaged file.txt", "hello"]
    end
  end
end

# frozen_string_literal: true

require_relative "test_helper"

class ConfigurationTest < Minitest::Test
  include WorkflowTestHelper

  def test_computes_route_floor
    with_root do |root|
      config = AIWorkflow::Configuration.new(root)
      assert_equal "quick", config.minimum_route(["README.md", "Docs/a.md"])
      assert_equal "standard", config.minimum_route(["src/view.rb"])
      assert_equal "spec", config.minimum_route(["infra/deploy.yml"])
      assert_equal "spec", config.minimum_route(["src/auth_token.rb"])
    end
  end

  def test_spec_runs_standard_and_spec_commands
    with_root do |root|
      config = AIWorkflow::Configuration.new(root)
      assert_equal ["ruby -v"], config.validation_commands("standard")
      assert_equal ["ruby -v", "git --version"], config.validation_commands("spec")
    end
  end
end

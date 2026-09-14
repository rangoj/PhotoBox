# frozen_string_literal: true

require_relative "test_helper"

class ReporterTest < Minitest::Test
  def test_exit_code_precedence
    output = StringIO.new
    reporter = AIWorkflow::Reporter.new(output: output)
    reporter.add("UNVERIFIED", "check", "missing")
    assert_equal 3, reporter.exit_code
    reporter.add("UNVERIFIED", "environment", "tool")
    assert_equal 4, reporter.exit_code
    reporter.add("FAIL", "gate", "bad")
    assert_equal 1, reporter.exit_code
  end
end

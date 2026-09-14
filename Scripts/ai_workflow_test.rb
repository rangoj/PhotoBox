# frozen_string_literal: true

require "minitest/autorun"

Dir[File.expand_path("ai_workflow_tests/*_test.rb", __dir__)].sort.each { |file| require file }

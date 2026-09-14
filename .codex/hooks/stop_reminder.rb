#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

JSON.parse($stdin.read)
message = <<~TEXT
  Before declaring the task complete, confirm the selected route, run the final
  Validation Harness and ./Scripts/ai-workflow validate, complete required
  read-only reviewers, verify the OpenSpec change for Spec work, and report
  PASS/FAIL/UNVERIFIED evidence, environment, and residual risk. This Hook is
  only a reminder and ran no checks.
TEXT

puts JSON.generate(continue: true, systemMessage: message.strip)

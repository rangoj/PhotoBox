#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

JSON.parse($stdin.read)
context = <<~TEXT
  Portable AI coding workflow is active. Before editing, read AGENTS.md when
  present and WORKFLOW.md; select Quick, Standard, or Spec; state Why, Context,
  and a repeatable Validation Harness with observable pass/fail signals. Routes
  may upgrade but may not downgrade below the configured minimum. Spec requires
  an approved OpenSpec change. Use applicable Superpowers methods without
  duplicating OpenSpec's canonical requirements, design, or tasks.
TEXT

puts JSON.generate(
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: context.strip
  }
)

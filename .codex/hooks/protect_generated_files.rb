#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "shellwords"
require "yaml"

def deny(reason)
  puts JSON.generate(
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: reason
    }
  )
end

input = JSON.parse($stdin.read)
root = `git rev-parse --show-toplevel 2>/dev/null`.strip
exit 0 if root.empty?

registry_path = File.join(root, ".ai-workflow/generated-files.yml")
exit 0 unless File.file?(registry_path)
registry = YAML.safe_load(File.read(registry_path), permitted_classes: [], aliases: false) || {}
entries = Array(registry["files"])
outputs = entries.map { |entry| entry["output"] }.compact
tool = input["tool_name"].to_s
payload = input["tool_input"] || {}

if tool == "apply_patch"
  patch = payload["command"].to_s
  targets = patch.scan(/^\*\*\* (?:Add|Update|Delete) File: (.+)$/).flatten
  targets.concat(patch.scan(/^\*\*\* Move to: (.+)$/).flatten)
  targets.map! do |path|
    expanded = File.expand_path(path, root)
    expanded.start_with?("#{root}/") ? expanded.delete_prefix("#{root}/") : path
  end
  matched = outputs.find { |path| targets.include?(path) }
  if matched
    deny("Direct edit blocked for generated file #{matched}. Change its registered source and run its verify command.")
  end
  exit 0
end

path_values = %w[file_path path].map { |key| payload[key].to_s }.reject(&:empty?)
matched = outputs.find do |output|
  path_values.any? do |value|
    File.expand_path(value, root) == File.expand_path(output, root)
  end
end
if matched
  deny("Direct edit blocked for generated file #{matched}. Change its registered source and run its verify command.")
  exit 0
end

exit 0 unless tool == "Bash"
command = payload["command"].to_s.strip
matched = outputs.find { |output| command.include?(output) }
exit 0 unless matched

allowed = entries.map { |entry| entry["verify"].to_s.strip }.reject(&:empty?).include?(command)
mutating = command.match?(/(?:^|\s)(?:cp|mv|rm|touch|tee|truncate|sed\s+-i|perl\s+-pi)(?:\s|$)|(?:^|[^<])>(?:>|\s)/)
exit 0 if allowed || !mutating

deny("Shell edit blocked for generated file #{matched}. Use the exact registered verify/generator command.")

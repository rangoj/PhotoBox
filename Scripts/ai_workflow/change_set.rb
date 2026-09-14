# frozen_string_literal: true

require "open3"
require "set"

module AIWorkflow
  class GitError < StandardError; end

  class ChangeSet
    def initialize(root)
      @root = File.expand_path(root)
    end

    def paths
      @paths ||= begin
        values = Set.new
        values.merge(nul_names("diff", "--name-only", "-z", "--cached"))
        values.merge(nul_names("diff", "--name-only", "-z"))
        values.merge(nul_names("ls-files", "--others", "--exclude-standard", "-z"))
        values.to_a.sort
      end
    end

    def added_lines
      @added_lines ||= begin
        lines = []
        nul_names("diff", "--name-only", "-z", "--cached").each do |path|
          lines.concat(diff_lines(path, "diff", "--no-ext-diff", "--unified=0", "--cached", "--", path))
        end
        nul_names("diff", "--name-only", "-z").each do |path|
          lines.concat(diff_lines(path, "diff", "--no-ext-diff", "--unified=0", "--", path))
        end
        nul_names("ls-files", "--others", "--exclude-standard", "-z").each do |path|
          absolute = File.join(@root, path)
          next unless File.file?(absolute)
          next if File.binread(absolute, 8192).to_s.include?("\0")
          File.foreach(absolute, chomp: true) { |line| lines << [path, line] }
        rescue ArgumentError, Encoding::InvalidByteSequenceError
          next
        end
        lines
      end
    end

    private

    def nul_names(*arguments)
      git(*arguments).split("\0").reject(&:empty?)
    end

    def diff_lines(path, *arguments)
      git(*arguments).each_line.each_with_object([]) do |line, values|
        next unless line.start_with?("+") && !line.start_with?("+++")
        values << [path, line.delete_prefix("+").chomp]
      end
    end

    def git(*arguments)
      stdout, stderr, status = Open3.capture3("git", *arguments, chdir: @root)
      raise GitError, stderr.strip unless status.success?
      stdout
    end
  end
end

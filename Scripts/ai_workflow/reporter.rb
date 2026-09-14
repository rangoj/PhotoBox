# frozen_string_literal: true

module AIWorkflow
  Result = Struct.new(:status, :name, :detail, keyword_init: true)

  class Reporter
    STATUSES = %w[PASS FAIL WARN UNVERIFIED SKIP].freeze
    attr_reader :results

    def initialize(output: $stdout)
      @output = output
      @results = []
    end

    def add(status, name, detail)
      raise ArgumentError, "Unknown status: #{status}" unless STATUSES.include?(status)
      results << Result.new(status: status, name: name, detail: detail)
      @output.puts format("%-12s %-24s %s", "[#{status}]", name, detail)
    end

    def exit_code
      return 1 if results.any? { |result| result.status == "FAIL" }
      return 4 if results.any? { |result| result.status == "UNVERIFIED" && result.name == "environment" }
      return 3 if results.any? { |result| result.status == "UNVERIFIED" }
      0
    end

    def summary
      counts = STATUSES.map { |status| [status, results.count { |item| item.status == status }] }.to_h
      @output.puts
      @output.puts STATUSES.map { |status| "#{status}=#{counts.fetch(status)}" }.join(" ")
      @output.puts "Exit=#{exit_code}"
    end
  end
end

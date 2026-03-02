# frozen_string_literal: true

require 'json'
require 'octokit'

module SimpleCovDelta
  # Phase 2: Comparison
  #
  # Compares the current merged .resultset.json against a baseline resultset and computes:
  # - Overall coverage delta
  # - Per-group coverage delta
  # - Per-file coverage delta
  # - Uncovered lines in changed files
  #
  # Requires baseline_path to be set; if not found, comparison is skipped.
  #
  # Environment Variables:
  # - COVERAGE_PATH: Directory for coverage data (default: 'coverage')
  # - BASELINE_PATH: Path to baseline .resultset.json file (required)
  # - SIMPLECOV_GROUPS: Newline-separated group definitions (format: 'Name:path')
  # - GITHUB_EVENT_PATH: GitHub Actions event.json for PR info
  # - GITHUB_REPOSITORY: GitHub repository in owner/name format
  # - GITHUB_TOKEN: GitHub API token
  # - GITHUB_API_URL: GitHub API URL (default: 'https://api.github.com')
  #
  class Compare
    PATH_PREFIXES = [
      %r{^/home/runner/work/[^/]+/[^/]+/},
      %r{^/github/workspace/},
      %r{^/app/},
      %r{^/}
    ].freeze

    # Main entry point for the comparison phase.
    #
    # Loads current and baseline resultsets, performs comparison, computes deltas,
    # and writes comparison results to disk. Skips if baseline is not found.
    #
    # @return [void]
    #
    # @raise [SystemExit] If current resultset not found
    def run
      current_resultset = File.join(coverage_path, '.resultset.json')
      abort "Error: Current resultset not found at #{current_resultset}" unless File.exist?(current_resultset)

      return puts 'No baseline file found — skipping comparison.' unless File.exist?(baseline_path)

      puts "Comparing #{current_resultset} against #{baseline_path}..."

      current_files = parse_resultset(current_resultset)
      baseline_files = parse_resultset(baseline_path)

      comparison = build_comparison(current_files, baseline_files)
      write_comparison(comparison)
      print_summary(comparison)
    end

    # Public utility methods (tested directly in specs)

    # @return [String] Coverage directory path from COVERAGE_PATH environment variable
    #
    def coverage_path
      @coverage_path ||= ENV.fetch('COVERAGE_PATH', 'coverage')
    end

    # @return [String] Baseline resultset path from BASELINE_PATH environment variable
    #
    def baseline_path
      @baseline_path ||= ENV.fetch('BASELINE_PATH', '')
    end

    # @return [Array<String>] Group definitions from SIMPLECOV_GROUPS (format: 'Name:path')
    #
    def groups_input
      @groups_input ||= ENV.fetch('SIMPLECOV_GROUPS', '').split("\n").map(&:strip).reject(&:empty?)
    end

    # @return [String] GitHub repository in owner/name format from GITHUB_REPOSITORY
    #
    def repository
      @repository ||= ENV.fetch('GITHUB_REPOSITORY', '')
    end

    # @return [String] GitHub API token from GITHUB_TOKEN
    #
    def token
      @token ||= ENV.fetch('GITHUB_TOKEN', '')
    end

    # @return [String] GitHub API URL from GITHUB_API_URL (default: 'https://api.github.com')
    #
    def api_url
      @api_url ||= ENV.fetch('GITHUB_API_URL', 'https://api.github.com')
    end

    # @return [String] GitHub Actions event.json file path from GITHUB_EVENT_PATH
    #
    def event_path
      @event_path ||= ENV.fetch('GITHUB_EVENT_PATH', '')
    end

    # Removes workspace and CI environment prefixes from absolute file paths.
    #
    # @param absolute_path [String] Absolute file path from coverage data
    # @return [String] Normalized relative path
    #
    def normalize_path(absolute_path)
      path = absolute_path
      PATH_PREFIXES.each do |prefix|
        next unless path.match?(prefix)

        path = path.sub(prefix, '')
        break
      end
      path
    end

    # Parses a resultset file and extracts normalized file coverage data.
    #
    # @param path [String] Path to .resultset.json file
    # @return [Hash] File coverage data with normalized paths as keys, each containing line array
    #
    def parse_resultset(path)
      files = {}

      JSON.parse(File.read(path)).each_value do |command_data|
        coverage = command_data['coverage'] || {}
        coverage.each do |file_path, file_data|
          relative = normalize_path(file_path)
          lines = file_data.is_a?(Hash) ? (file_data['lines'] || []) : file_data
          merge_file_lines!(files, relative, lines)
        end
      end

      files
    end

    # Calculates coverage statistics for a file's line array.
    #
    # @param lines [Array] Line coverage array where nil=not executable, 0=uncovered, >0=covered N times
    # @return [Hash] Statistics with covered, total, and percentage keys
    #
    def file_coverage(lines)
      executable = lines.compact
      return { covered: 0, total: 0, percentage: 0.0 } if executable.empty?

      covered = executable.count(&:positive?)
      {
        covered: covered,
        total: executable.size,
        percentage: (covered.to_f / executable.size * 100).round(2)
      }
    end

    # Extracts uncovered line numbers from a file's line array.
    #
    # @param lines [Array] Line coverage array where 0 indicates uncovered
    # @return [Array<Integer>] 1-based line numbers that are uncovered
    #
    def uncovered_lines(lines)
      result = []
      lines.each_with_index do |count, i|
        result << (i + 1) if !count.nil? && count.zero?
      end
      result
    end

    # Calculates group coverage statistics from file coverage data.
    #
    # @param files [Hash] File coverage data with normalized paths as keys
    # @param group_definitions [Array<Hash>] Group definitions with name and path keys
    # @return [Array<Hash>] Group statistics with name, coverage percentage, total, and covered keys
    #
    def group_coverage(files, group_definitions)
      group_definitions.map do |group_def|
        group_total = 0
        group_covered = 0

        files.each do |path, data|
          next unless path.include?(group_def[:path])

          stats = file_coverage(data[:lines])
          group_total += stats[:total]
          group_covered += stats[:covered]
        end

        pct = group_total.positive? ? (group_covered.to_f / group_total * 100).round(2) : 0.0
        { name: group_def[:name], coverage: pct, total: group_total, covered: group_covered }
      end
    end

    private

    # --- Comparison building ---

    # Builds complete comparison between current and baseline resultsets.
    #
    # @param current_files [Hash] Current file coverage data
    # @param baseline_files [Hash] Baseline file coverage data
    # @return [Hash] Comparison with overall, groups, changed_files, and all_changed_coverage_files
    #
    def build_comparison(current_files, baseline_files)
      changed_files_list = fetch_changed_files
      puts "Changed files in PR: #{changed_files_list.size}"

      {
        overall: calculate_overall_delta(current_files, baseline_files),
        groups: calculate_group_deltas(current_files, baseline_files),
        changed_files: compare_changed_files(current_files, baseline_files, changed_files_list),
        all_changed_coverage_files: find_all_changed_coverage(current_files, baseline_files, changed_files_list)
      }
    end

    # --- Overall coverage ---

    # Calculates overall coverage percentage from file coverage data.
    #
    # @param files [Hash] File coverage data with normalized paths as keys
    # @return [Float] Overall coverage percentage
    #
    def calculate_overall(files)
      total = 0
      covered = 0

      files.each_value do |data|
        stats = file_coverage(data[:lines])
        total += stats[:total]
        covered += stats[:covered]
      end

      total.positive? ? (covered.to_f / total * 100).round(2) : 0.0
    end

    # Calculates overall coverage delta between current and baseline.
    #
    # @param current_files [Hash] Current file coverage data
    # @param baseline_files [Hash] Baseline file coverage data
    # @return [Hash] Overall delta with current, baseline, and delta keys
    #
    def calculate_overall_delta(current_files, baseline_files)
      current_overall = calculate_overall(current_files)
      baseline_overall = calculate_overall(baseline_files)

      {
        current: current_overall,
        baseline: baseline_overall,
        delta: (current_overall - baseline_overall).round(2)
      }
    end

    # --- Group coverage ---

    # Parses group definitions from configuration.
    #
    # @return [Array<Hash>] Group definitions with name and path keys
    #
    def group_definitions
      @group_definitions ||= groups_input.map do |group_def|
        name, path = group_def.split(':', 2)
        { name: name.strip, path: path.strip }
      end
    end

    # Calculates per-group coverage deltas between current and baseline.
    #
    # @param current_files [Hash] Current file coverage data
    # @param baseline_files [Hash] Baseline file coverage data
    # @return [Array<Hash>] Group deltas with name, current, baseline, and delta keys
    #
    def calculate_group_deltas(current_files, baseline_files)
      current_groups = group_coverage(current_files, group_definitions)
      baseline_groups = group_coverage(baseline_files, group_definitions)

      current_groups.map do |cg|
        bg = baseline_groups.find { |g| g[:name] == cg[:name] }
        baseline_pct = bg ? bg[:coverage] : nil
        delta = baseline_pct ? (cg[:coverage] - baseline_pct).round(2) : nil
        { name: cg[:name], current: cg[:coverage], baseline: baseline_pct, delta: delta }
      end
    end

    # --- Changed files ---

    # Compares coverage for files changed in the PR.
    #
    # @param current_files [Hash] Current file coverage data
    # @param baseline_files [Hash] Baseline file coverage data
    # @param changed_files_list [Array<String>] Paths to files changed in PR
    # @return [Array<Hash>] Coverage results for changed files with path, coverage, and delta
    #
    def compare_changed_files(current_files, baseline_files, changed_files_list)
      changed_files_list.filter_map do |changed_path|
        current_data = current_files[changed_path]
        next unless current_data

        build_changed_file_result(changed_path, current_data, baseline_files[changed_path])
      end
    end

    # Builds detailed comparison result for a single changed file.
    #
    # @param path [String] File path
    # @param current_data [Hash] Current file coverage data
    # @param baseline_data [Hash, nil] Baseline file coverage data if exists
    # @return [Hash] Result with path, current, baseline, delta, and uncovered_lines
    #
    def build_changed_file_result(path, current_data, baseline_data)
      current_stats = file_coverage(current_data[:lines])
      uncovered = uncovered_lines(current_data[:lines])
      result = { path: path, current: current_stats[:percentage], uncovered_lines: uncovered }

      if baseline_data
        baseline_stats = file_coverage(baseline_data[:lines])
        result.merge(baseline: baseline_stats[:percentage],
                     delta: (current_stats[:percentage] - baseline_stats[:percentage]).round(2))
      else
        result.merge(baseline: nil, delta: nil)
      end
    end

    # Finds all files (not in PR changed list) with coverage changes.
    #
    # @param current_files [Hash] Current file coverage data
    # @param baseline_files [Hash] Baseline file coverage data
    # @param changed_files_list [Array<String>] Files changed in PR (to exclude)
    # @return [Array<Hash>] Files with coverage changes, sorted by largest delta
    #
    def find_all_changed_coverage(current_files, baseline_files, changed_files_list)
      all_paths = (current_files.keys + baseline_files.keys).uniq

      results = all_paths.filter_map do |path|
        next if changed_files_list.include?(path)

        delta = calculate_file_delta(current_files[path], baseline_files[path])
        next if delta[:delta].zero?

        { path: path, current: delta[:current], baseline: delta[:baseline], delta: delta[:delta] }
      end

      results.sort_by { |f| -f[:delta].abs }
    end

    # Calculates coverage delta for a single file.
    #
    # @param current_data [Hash, nil] Current file coverage data
    # @param baseline_data [Hash, nil] Baseline file coverage data
    # @return [Hash] Delta with current, baseline, and delta keys
    #
    def calculate_file_delta(current_data, baseline_data)
      current_pct = current_data ? file_coverage(current_data[:lines])[:percentage] : 0.0
      baseline_pct = baseline_data ? file_coverage(baseline_data[:lines])[:percentage] : 0.0
      { current: current_pct, baseline: baseline_pct, delta: (current_pct - baseline_pct).round(2) }
    end

    # --- Line merging ---

    # Merges line coverage data for a file from multiple runs.
    #
    # @param files [Hash] Target files hash to merge into (modified in place)
    # @param relative [String] Normalized relative file path
    # @param lines [Array] Line coverage array to merge in
    # @return [void]
    #
    def merge_file_lines!(files, relative, lines)
      if files[relative]
        existing = files[relative][:lines]
        lines.each_with_index do |count, i|
          next if count.nil?

          existing[i] = existing[i].nil? ? count : existing[i] + count
        end
      else
        files[relative] = { lines: lines.dup }
      end
    end

    # --- GitHub API ---

    # Fetches list of files changed in the current PR from GitHub API.
    #
    # Reads PR number from GITHUB_EVENT_PATH and uses Octokit to fetch changed files.
    # Returns empty array if not in a PR context or API call fails.
    #
    # @return [Array<String>] Paths to files changed in the PR
    #
    def fetch_changed_files
      return [] unless event_path && File.exist?(event_path)

      event = JSON.parse(File.read(event_path))
      pr_number = event.dig('pull_request', 'number')
      return [] unless pr_number

      client = Octokit::Client.new(access_token: token, api_endpoint: api_url, auto_paginate: true)
      files = client.pull_request_files(repository, pr_number)
      files.map(&:filename)
    rescue Octokit::Error => e
      warn "Warning: Failed to fetch PR files: #{e.message}"
      []
    end

    # --- Output ---

    # Writes comparison results to comparison.json file.
    #
    # @param comparison [Hash] Complete comparison result
    # @return [void]
    #
    def write_comparison(comparison)
      output_path = File.join(coverage_path, 'comparison.json')
      File.write(output_path, JSON.pretty_generate(comparison))
    end

    # Prints comparison summary to console.
    #
    # @param comparison [Hash] Complete comparison result with overall and file change counts
    # @return [void]
    #
    def print_summary(comparison)
      overall = comparison[:overall]
      delta_sign = overall[:delta] >= 0 ? '+' : ''

      puts "\nComparison complete!\n" \
           "  Current: #{overall[:current]}%\n" \
           "  Baseline: #{overall[:baseline]}%\n" \
           "  Delta: #{delta_sign}#{overall[:delta]}%\n" \
           "  Changed files analyzed: #{comparison[:changed_files].size}\n" \
           "  Other files with coverage changes: #{comparison[:all_changed_coverage_files].size}\n" \
           "  Output: #{File.join(coverage_path, 'comparison.json')}"
    end
  end
end

SimpleCovDelta::Compare.new.run if __FILE__ == $PROGRAM_NAME

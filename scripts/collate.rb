# frozen_string_literal: true

require 'simplecov'
require 'json'
require 'fileutils'

module SimpleCovDelta
  # Phase 1: Collation
  #
  # Merges multiple .resultset.json files, generates HTML report, and computes
  # overall coverage statistics by file and group.
  #
  # Environment Variables:
  # - COVERAGE_PATH: Directory for coverage data (default: 'coverage')
  # - RESULTSET_PATHS: Newline-separated glob patterns for .resultset.json files
  # - SIMPLECOV_PROFILE: SimpleCov profile to use (default: 'rails')
  # - SIMPLECOV_FILTERS: Newline-separated regex filters to apply
  # - SIMPLECOV_GROUPS: Newline-separated group definitions (format: 'Name:path')
  # - GITHUB_WORKSPACE: Working directory (default: Dir.pwd)
  #
  class Collate
    PATH_PREFIXES = [
      %r{^/home/runner/work/[^/]+/[^/]+/},
      %r{^/runner/_work/[^/]+/[^/]+/},
      %r{^/github/workspace/},
      %r{^/app/}
    ].freeze

    # Main entry point for the collation phase.
    #
    # Creates coverage directory, discovers and validates .resultset.json files, merges them,
    # generates HTML report, computes coverage statistics, and writes results to disk.
    #
    #
    # @raise [SystemExit] If no resultset files found or no coverage data found
    def run
      FileUtils.mkdir_p(coverage_path)

      resultset_files = find_resultset_files
      merged_coverage = validate_and_merge(resultset_files)
      merged_resultset_path = write_merged_resultset(merged_coverage)

      log_merged_structure(merged_coverage)
      generate_html_report(merged_resultset_path)

      coverage_result = build_coverage_result(merged_coverage)
      write_coverage_result(coverage_result)
      print_summary(coverage_result)
    end

    private

    # @return [String] Coverage directory path from COVERAGE_PATH environment variable
    #
    def coverage_path
      @coverage_path ||= ENV.fetch('COVERAGE_PATH', 'coverage')
    end

    # @return [Array<String>] Glob patterns for discovering resultset files from RESULTSET_PATHS
    #
    def resultset_patterns
      @resultset_patterns ||= ENV.fetch('RESULTSET_PATHS', '').split("\n").map(&:strip).reject(&:empty?)
    end

    # @return [String] SimpleCov profile name from SIMPLECOV_PROFILE (default: 'rails')
    #
    def profile
      @profile ||= ENV.fetch('SIMPLECOV_PROFILE', 'rails')
    end

    # @return [Array<String>] Regex patterns for coverage filters from SIMPLECOV_FILTERS
    #
    def filters
      @filters ||= ENV.fetch('SIMPLECOV_FILTERS', '').split("\n").map(&:strip).reject(&:empty?)
    end

    # @return [Array<String>] Group definitions from SIMPLECOV_GROUPS (format: 'Name:path')
    #
    def groups
      @groups ||= ENV.fetch('SIMPLECOV_GROUPS', '').split("\n").map(&:strip).reject(&:empty?)
    end

    # @return [String] Workspace directory from GITHUB_WORKSPACE (default: current working directory)
    #
    def workspace
      @workspace ||= ENV.fetch('GITHUB_WORKSPACE', Dir.pwd)
    end

    # --- File discovery ---

    # Finds all .resultset.json files matching configured patterns.
    #
    # @return [Array<String>] Paths to discovered resultset files
    #
    # @raise [SystemExit] If no files matching patterns are found
    def find_resultset_files
      files = resultset_patterns.flat_map { |pattern| Dir.glob(pattern) }.uniq

      abort "Error: No .resultset.json files found matching patterns: #{resultset_patterns.join(', ')}" if files.empty?

      puts "Found #{files.size} resultset file(s):"
      files.each { |f| puts "  - #{f}" }
      files
    end

    # --- Merging ---

    # Validates and merges multiple resultset files into a single coverage hash.
    #
    # @param resultset_files [Array<String>] Paths to .resultset.json files to merge
    # @return [Hash] Merged coverage data with file paths as keys, line arrays as values
    #
    # @raise [SystemExit] If no coverage data found in any resultset
    def validate_and_merge(resultset_files)
      puts "\n📋 Validating resultset files:"
      merged_coverage = {}
      total_coverage_found = 0

      resultset_files.each do |file|
        total_coverage_found += merge_single_resultset!(merged_coverage, file)
      end

      if total_coverage_found.zero?
        abort 'Error: No coverage files found in any resultset. Check that test jobs are generating coverage data.'
      end

      merged_coverage
    end

    # Parses and merges a single resultset file into the merged coverage hash.
    #
    # @param merged_coverage [Hash] Target hash to merge coverage into (modified in place)
    # @param file [String] Path to .resultset.json file to parse and merge
    # @return [Integer] Number of files found in the resultset
    #
    # @raise [SystemExit] If file is invalid JSON or cannot be read
    def merge_single_resultset!(merged_coverage, file)
      coverage_count = 0

      JSON.parse(File.read(file)).each_value do |command_data|
        coverage = command_data['coverage'] || {}
        coverage_count += coverage.size
        merge_resultset_coverage!(merged_coverage, coverage)
      end

      puts "  ✓ #{File.basename(file)} - #{File.size(file)} bytes, #{coverage_count} files"
      coverage_count
    rescue StandardError => e
      abort "Error reading #{file}: #{e.message}"
    end

    # Merges coverage data from a single command execution into the merged coverage.
    #
    # @param merged_coverage [Hash] Target hash to merge into (modified in place)
    # @param coverage [Hash] Coverage data with file paths as keys and line arrays as values
    #
    def merge_resultset_coverage!(merged_coverage, coverage)
      coverage.each do |file_path, file_data|
        normalized = normalize_path(file_path)
        lines = file_data.is_a?(Hash) ? (file_data['lines'] || []) : file_data

        existing = merged_coverage[normalized]
        if existing.nil?
          merged_coverage[normalized] = lines.dup
        else
          merge_lines!(existing, lines)
        end
      end
    end

    # Merges line coverage data from current run with existing coverage.
    #
    # Updates line counts by summing hits from both sources, extending array if needed.
    #
    # @param existing [Array] Existing line coverage array (modified in place)
    # @param lines [Array] New line coverage array to merge in
    #
    def merge_lines!(existing, lines)
      existing.fill(nil, existing.length...lines.length) if existing.length < lines.length

      lines.each_with_index do |count, i|
        next if count.nil?

        existing[i] = existing[i].nil? ? count : existing[i] + count
      end
    end

    # --- Output ---

    # Writes merged resultset to .resultset.json file.
    #
    # @param merged_coverage [Hash] Merged coverage data with file paths as keys
    # @return [String] Path to written merged resultset file
    #
    def write_merged_resultset(merged_coverage)
      puts "\n🔀 Manually merging resultsets..."
      merged_data = {
        'merged' => { 'coverage' => merged_coverage, 'timestamp' => Time.now.to_i }
      }

      path = File.join(coverage_path, '.resultset.json')
      File.write(path, JSON.generate(merged_data))
      puts "✓ Merged .resultset.json generated (#{File.size(path)} bytes)"
      path
    end

    # Logs the structure of merged coverage for debugging.
    #
    # @param merged_coverage [Hash] Merged coverage data
    #
    def log_merged_structure(merged_coverage)
      puts "\n📊 Merged result structure:"
      puts "  merged: #{merged_coverage.size} files"
    end

    # Writes coverage result JSON file.
    #
    # @param coverage_result [Hash] Coverage result with aggregated statistics
    #
    def write_coverage_result(coverage_result)
      result_path = File.join(coverage_path, 'coverage_result.json')
      File.write(result_path, JSON.pretty_generate(coverage_result))
    end

    # Prints collation summary with coverage statistics to console.
    #
    # @param coverage_result [Hash] Coverage result with total coverage and group breakdowns
    #
    def print_summary(coverage_result)
      puts "\n✅ Collation complete!\n" \
              "  Total coverage: #{coverage_result[:total_coverage]}%\n" \
              "  Total lines: #{coverage_result[:total_lines]}\n" \
              "  Covered lines: #{coverage_result[:covered_lines]}"
      coverage_result[:groups].each { |g| puts "  #{g[:name]}: #{g[:coverage]}%" }
      puts "  Merged resultset: #{File.join(coverage_path, '.resultset.json')}\n" \
           "  Coverage result: #{File.join(coverage_path, 'coverage_result.json')}"
    end

    # --- Coverage calculation ---

    # Builds the final coverage result with aggregated statistics.
    #
    # @param merged_coverage [Hash] Merged coverage data with file paths as keys
    # @return [Hash] Coverage result with total_coverage, total_lines, covered_lines, files array, and groups array
    #
    def build_coverage_result(merged_coverage)
      file_coverages, total_lines, covered_lines = calculate_file_coverages(merged_coverage)
      total_coverage = total_lines.positive? ? (covered_lines.to_f / total_lines * 100).round(2) : 0.0

      {
        total_coverage: total_coverage,
        total_lines: total_lines,
        covered_lines: covered_lines,
        files: file_coverages,
        groups: calculate_group_coverages(merged_coverage)
      }
    end

    # Calculates coverage percentages for each file.
    #
    # @param merged_coverage [Hash] Merged coverage data with file paths as keys
    # @return [Array<(Array<Hash>, Integer, Integer)>] Tuple of file coverages array, total lines, and covered lines
    #
    def calculate_file_coverages(merged_coverage)
      total_lines = 0
      covered_lines = 0
      file_coverages = []

      merged_coverage.each do |file_path, lines|
        stats = file_coverage(lines)
        total_lines += stats[:total]
        covered_lines += stats[:covered]
        next if stats[:total].zero?

        file_coverages << build_file_entry(file_path, stats)
      end

      [file_coverages.sort_by { |f| f[:path] }, total_lines, covered_lines]
    end

    # Builds a single file entry for coverage result.
    #
    # @param file_path [String] Absolute or relative file path
    # @param stats [Hash] File statistics with covered, total, percentage, and uncovered keys
    # @return [Hash] File entry with path, coverage percentage, line counts, and uncovered line numbers
    #
    def build_file_entry(file_path, stats)
      {
        path: relative_path(file_path),
        coverage: stats[:percentage],
        total_lines: stats[:total],
        covered_lines: stats[:covered],
        uncovered_lines: stats[:uncovered]
      }
    end

    # Calculates group coverage statistics from merged coverage.
    #
    # @param merged_coverage [Hash] Merged coverage data with file paths as keys
    # @return [Array<Hash>] Array of group statistics with name, coverage percentage, and line counts
    #
    def calculate_group_coverages(merged_coverage)
      group_definitions.filter_map do |group_def|
        totals = group_totals(merged_coverage, group_def)
        next unless totals[:total].positive?

        pct = (totals[:covered].to_f / totals[:total] * 100).round(2)
        { name: group_def[:name], coverage: pct, total_lines: totals[:total], covered_lines: totals[:covered] }
      end
    end

    # Parses group definitions from configuration.
    #
    # @return [Array<Hash>] Array of group definitions with name and path keys
    #
    def group_definitions
      @group_definitions ||= groups.map do |group_def|
        name, path = group_def.split(':', 2)
        { name: name.strip, path: path.strip }
      end
    end

    # Aggregates coverage totals for a specific group.
    #
    # @param merged_coverage [Hash] Merged coverage data with file paths as keys
    # @param group_def [Hash] Group definition with name and path keys
    # @return [Hash] Totals hash with total and covered line counts
    #
    def group_totals(merged_coverage, group_def)
      total = 0
      covered = 0

      merged_coverage.each do |file_path, lines|
        next unless relative_path(file_path).include?(group_def[:path])

        stats = file_coverage(lines)
        total += stats[:total]
        covered += stats[:covered]
      end

      { total: total, covered: covered }
    end

    # Calculates coverage statistics for a file's line array.
    #
    # @param lines [Array] Line coverage array where nil=not executable, 0=uncovered, >0=covered N times
    # @return [Hash] Statistics with covered, total, percentage, and uncovered line numbers
    #
    def file_coverage(lines)
      executable = lines.compact
      return { covered: 0, total: 0, percentage: 0.0, uncovered: [] } if executable.empty?

      covered = executable.count(&:positive?)
      uncovered = []
      lines.each_with_index do |count, i|
        uncovered << (i + 1) if !count.nil? && count.zero?
      end

      { covered: covered, total: executable.size, uncovered: uncovered,
        percentage: (covered.to_f / executable.size * 100).round(2) }
    end

    # --- Path helpers ---

    # Normalizes file paths by removing workspace prefixes.
    #
    # Handles paths from various CI environments and absolute paths.
    #
    # @param path [String] File path to normalize
    # @return [String] Normalized relative path
    #
    def normalize_path(path)
      relative = path.to_s
      PATH_PREFIXES.each do |prefix|
        next unless relative.match?(prefix)

        relative = relative.sub(prefix, '')
        break
      end

      return relative if relative.start_with?(workspace)

      File.expand_path(relative.sub(%r{^/}, ''), workspace)
    end

    # Converts absolute path to relative path within workspace.
    #
    # @param path [String] Absolute file path
    # @return [String] Path relative to workspace directory
    #
    def relative_path(path)
      path.sub(%r{^#{Regexp.escape(workspace)}/?}, '')
    end

    # --- HTML report ---

    # Generates HTML report using SimpleCov from merged resultset.
    #
    # Applies configured filters, groups, and profile. Logs warning if errors occur.
    #
    # @param merged_resultset_path [String] Path to merged .resultset.json file
    #
    def generate_html_report(merged_resultset_path)
      puts "\n📊 Generating HTML report from merged result using profile '#{profile}'..."
      SimpleCov.coverage_dir(coverage_path)
      SimpleCov.formatters = [SimpleCov::Formatter::HTMLFormatter]

      SimpleCov.collate([merged_resultset_path], profile) do
        filters.each { |filter_regex| add_filter Regexp.new(filter_regex) }
        groups.map { |gd| gd.split(':', 2) }.each do |name, path|
          add_group(name.strip, path.strip) if name && path
        end
      end
      puts '✓ HTML report generated'
    end
  end
end

SimpleCovDelta::Collate.new.run if __FILE__ == $PROGRAM_NAME

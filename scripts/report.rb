# frozen_string_literal: true

require 'json'
require 'octokit'

module SimpleCovDelta
  # Phase 3: Reporting
  #
  # Creates GitHub Check Run annotations for uncovered lines, writes Job Summary,
  # and posts or updates a PR comment with coverage report.
  #
  # Environment Variables:
  # - COVERAGE_PATH: Directory for coverage data (default: 'coverage')
  # - GITHUB_REPOSITORY: GitHub repository in owner/name format
  # - GITHUB_SHA: Git commit SHA for check run
  # - GITHUB_RUN_ID: GitHub Actions run ID for report link
  # - GITHUB_TOKEN: GitHub API token
  # - GITHUB_SERVER_URL: GitHub server URL (default: 'https://github.com')
  # - GITHUB_API_URL: GitHub API URL (default: 'https://api.github.com')
  # - GITHUB_EVENT_PATH: Path to GitHub Actions event.json
  # - GITHUB_STEP_SUMMARY: Path to job summary file
  # - CHECK_NAME: Name for check run (default: 'Coverage Report')
  # - MIN_COVERAGE: Minimum coverage threshold percentage (default: '0')
  # - ANNOTATIONS: Whether to create check run annotations (default: 'true')
  # - POST_COMMENT: Whether to post/update PR comment (default: 'true')
  #
  # @attr_reader [String] COMMENT_MARKER HTML comment marker for tracking PR comments
  # @attr_reader [Integer] MAX_ANNOTATIONS_PER_CALL Maximum annotations per API call (50)
  class Report
    COMMENT_MARKER = '<!-- coverage-report-action -->'
    MAX_ANNOTATIONS_PER_CALL = 50

    # Main entry point for the reporting phase.
    #
    # Loads coverage results and comparison data, builds annotations and markdown reports,
    # creates GitHub check run, writes job summary, and posts/updates PR comment.
    #
    def run
      coverage_result = load_coverage_result
      comparison = load_comparison

      annotations = build_annotations(comparison)
      puts "Built #{annotations.size} annotation(s)"

      create_check_run(annotations, coverage_result, comparison)

      summary_md = build_job_summary(coverage_result, comparison)
      write_job_summary(summary_md)

      comment_md = build_pr_comment(coverage_result, comparison)
      post_or_update_pr_comment(comment_md)

      puts 'Reporting complete!'
    end

    # --- Public formatting methods (tested directly in specs) ---

    # Formats coverage delta with indicator emoji.
    #
    # @param delta [Float, nil] Coverage delta percentage (nil if no baseline)
    # @return [String] Formatted delta with emoji indicator (✅ for positive, ⚠️ for negative, — for nil)
    #
    def delta_indicator(delta)
      return '—' if delta.nil?

      formatted = format('%+.2f%%', delta)
      return "#{formatted} ✅" if delta.positive?
      return "#{formatted} ⚠️" if delta.negative?

      formatted
    end

    # Formats uncovered line numbers as human-readable ranges or single values.
    #
    # Groups consecutive lines into ranges (e.g., 1-5, 10-12) and individual lines.
    #
    # @param lines [Array<Integer>, nil] 1-based line numbers of uncovered lines
    # @return [String] Formatted line ranges or '—' if empty/nil
    #
    def format_uncovered_lines(lines)
      return '—' if lines.nil? || lines.empty?

      group_consecutive(lines.sort).map do |range|
        range.size == 1 ? range.first.to_s : "#{range.first}-#{range.last}"
      end.join(', ')
    end

    # Builds GitHub Check Run annotations from comparison data.
    #
    # Extracts uncovered line ranges from changed files and creates annotation objects.
    #
    # @param comparison [Hash, nil] Comparison data with changed_files
    # @return [Array<Hash>] Annotation objects with path, line numbers, and message
    #
    def build_annotations(comparison)
      return [] unless comparison

      (comparison['changed_files'] || []).flat_map do |file|
        uncovered = file['uncovered_lines'] || []
        next [] if uncovered.empty?

        ranges_to_annotations(file['path'], uncovered)
      end
    end

    # Builds markdown table of group coverage statistics.
    #
    # @param groups [Array<Hash>, nil] Group statistics with name and coverage data
    # @return [String] Markdown table or empty string if no groups
    #
    def build_groups_table(groups)
      return if groups.nil? || groups.empty?

      has_baseline = groups.any? { |g| g['baseline'] || g['delta'] }
      header = groups_table_header(has_baseline)
      rows = groups.map { |g| groups_table_row(g, has_baseline) }
      header + rows.join("\n")
    end

    # Builds markdown for PR comment with coverage report.
    #
    # Includes overall coverage, group comparison, and changed files.
    # Does not include full files list to keep comment concise.
    #
    # @param coverage_result [Hash] Coverage result with total_coverage and groups
    # @param comparison [Hash, nil] Comparison data (nil if no baseline)
    # @return [String] Markdown content for PR comment
    #
    def build_pr_comment(coverage_result, comparison)
      overall_pct = format('%.1f%%', coverage_result['total_coverage'])

      sections = [
        '## 📊 Coverage Report',
        overall_header(overall_pct, comparison),
        comparison_sections(comparison, coverage_result, include_all_changed: false),
        run_url_link
      ]
      "#{COMMENT_MARKER}\n#{sections.compact.join("\n\n")}\n"
    end

    # Builds markdown for GitHub Job Summary with full coverage report.
    #
    # Includes overall coverage, group comparison, changed files, and all files list.
    #
    # @param coverage_result [Hash] Coverage result with total_coverage, groups, and files
    # @param comparison [Hash, nil] Comparison data (nil if no baseline)
    # @return [String] Markdown content for job summary
    #
    def build_job_summary(coverage_result, comparison)
      overall_pct = format('%.1f%%', coverage_result['total_coverage'])

      ['## 📊 Coverage Report — Full Details',
       overall_header(overall_pct, comparison),
       comparison_sections(comparison, coverage_result, include_all_changed: true)].compact.join("\n\n")
    end

    private

    # @return [String] Coverage directory path from COVERAGE_PATH environment variable
    #
    def coverage_path
      @coverage_path ||= ENV.fetch('COVERAGE_PATH', 'coverage')
    end

    # @return [String] GitHub repository in owner/name format from GITHUB_REPOSITORY
    #
    def repository
      @repository ||= ENV.fetch('GITHUB_REPOSITORY', '')
    end

    # @return [String] GitHub Actions run URL built from server_url, repository, and run_id
    #
    #
    def run_url
      run_id = ENV.fetch('GITHUB_RUN_ID', '')
      server_url = ENV.fetch('GITHUB_SERVER_URL', 'https://github.com')
      @run_url ||= "#{server_url}/#{repository}/actions/runs/#{run_id}"
    end

    # @return [String] GitHub API token from GITHUB_TOKEN
    #
    #
    def token
      @token ||= ENV.fetch('GITHUB_TOKEN', '')
    end

    # @return [String] GitHub API URL from GITHUB_API_URL (default: 'https://api.github.com')
    #
    #
    def api_url
      @api_url ||= ENV.fetch('GITHUB_API_URL', 'https://api.github.com')
    end

    # @return [String] Git commit SHA from GITHUB_SHA
    #
    #
    def sha
      @sha ||= ENV.fetch('GITHUB_SHA', '')
    end

    # @return [String] Check run name from CHECK_NAME (default: 'Coverage Report')
    #
    #
    def check_name
      @check_name ||= ENV.fetch('CHECK_NAME', 'Coverage Report')
    end

    # @return [Float] Minimum coverage threshold percentage from MIN_COVERAGE (default: '0')
    #
    #
    def min_coverage
      @min_coverage ||= ENV.fetch('MIN_COVERAGE', '0').to_f
    end

    # @return [Boolean] Whether to create check run annotations from ANNOTATIONS (default: true)
    #
    #
    def annotations_enabled?
      @annotations_enabled ||= ENV.fetch('ANNOTATIONS', 'true') == 'true'
    end

    # @return [Boolean] Whether to post/update PR comment from POST_COMMENT (default: true)
    #
    #
    def post_comment_enabled?
      @post_comment_enabled ||= ENV.fetch('POST_COMMENT', 'true') == 'true'
    end

    # @return [String] GitHub Actions event.json file path from GITHUB_EVENT_PATH
    #
    #
    def event_path
      @event_path ||= ENV.fetch('GITHUB_EVENT_PATH', '')
    end

    # @return [String] GitHub Actions job summary file path from GITHUB_STEP_SUMMARY
    #
    #
    def step_summary_path
      @step_summary_path ||= ENV.fetch('GITHUB_STEP_SUMMARY', '')
    end

    # --- Data loading ---

    # Loads coverage result from coverage_result.json file.
    #
    # @return [Hash] Coverage result with total_coverage, groups, and files
    #
    # @raise [SystemExit] If coverage result file not found
    def load_coverage_result
      result_path = File.join(coverage_path, 'coverage_result.json')
      abort "Error: Coverage result not found at #{result_path}" unless File.exist?(result_path)
      JSON.parse(File.read(result_path))
    end

    # Loads comparison from comparison.json file if it exists.
    #
    # @return [Hash, nil] Comparison data with overall, groups, and changed_files, or nil if file not found
    #
    def load_comparison
      comparison_path = File.join(coverage_path, 'comparison.json')
      File.exist?(comparison_path) ? JSON.parse(File.read(comparison_path)) : nil
    end

    # --- Markdown building helpers ---

    # Builds overall coverage header with delta if comparison exists.
    #
    # @param overall_pct [String] Formatted overall coverage percentage
    # @param comparison [Hash, nil] Comparison data with overall delta (nil if no baseline)
    # @return [String] Markdown header line with coverage and optional delta
    #
    def overall_header(overall_pct, comparison)
      if comparison
        delta_str = delta_indicator(comparison['overall']['delta'])
        "**Overall: #{overall_pct}** (#{delta_str} vs baseline)"
      else
        "**Overall: #{overall_pct}**"
      end
    end

    # Builds conditional markdown sections for comparison or no-comparison scenarios.
    #
    # @param comparison [Hash, nil] Comparison data (nil if no baseline)
    # @param coverage_result [Hash] Coverage result data
    # @param include_all_changed [Boolean] Whether to include all files with coverage changes
    # @return [String] Markdown content with appropriate sections
    #
    def comparison_sections(comparison, coverage_result, include_all_changed:)
      return no_comparison_sections(coverage_result, include_all_files: include_all_changed) unless comparison

      sections = [groups_section(comparison_groups(comparison, coverage_result)),
                  changed_files_section(comparison['changed_files'])]
      sections << all_changed_section(comparison['all_changed_coverage_files']) if include_all_changed

      # In full job summary mode, keep detailed output even when comparison has
      # no per-group/file deltas (e.g., unchanged coverage between baseline/current).
      sections << all_files_section(coverage_result['files']) if include_all_changed && sections.compact.empty?

      sections.compact.join("\n\n")
    end

    # Selects group data for comparison-backed reports.
    #
    # Prefers comparison groups with baseline deltas, but falls back to the
    # current coverage groups so PR comments still show group coverage when no
    # changed files produced comparison rows.
    #
    # @param comparison [Hash] Comparison data
    # @param coverage_result [Hash] Coverage result data
    # @return [Array<Hash>, nil] Group rows suitable for build_groups_table
    #
    def comparison_groups(comparison, coverage_result)
      comparison_groups = comparison['groups']
      return comparison_groups unless comparison_groups.nil? || comparison_groups.empty?

      coverage_groups = coverage_result['groups']
      return if coverage_groups.nil? || coverage_groups.empty?

      coverage_groups.map { |group| { 'name' => group['name'], 'current' => group['coverage'] } }
    end

    # Builds 'By Group' section with group coverage table.
    #
    # @param groups [Array<Hash>, nil] Group statistics
    # @return [String] Markdown section or empty string if no groups
    #
    def groups_section(groups)
      return if groups.nil? || groups.empty?

      "### By Group\n\n#{build_groups_table(groups)}"
    end

    # Builds 'Changed Files' section with table of PR-changed files.
    #
    # @param changed_files [Array<Hash>, nil] Coverage for files changed in PR
    # @return [String] Markdown section or empty string if no changed files
    #
    def changed_files_section(changed_files)
      return if changed_files.nil? || changed_files.empty?

      "### Changed Files\n\n#{build_changed_files_table(changed_files)}"
    end

    # Builds 'All Files with Coverage Changes' section for files not in PR changes.
    #
    # @param all_changed [Array<Hash>, nil] Files with coverage changes outside PR scope
    # @return [String] Markdown section or empty string if no affected files
    #
    def all_changed_section(all_changed)
      return if all_changed.nil? || all_changed.empty?

      ['### All Files with Coverage Changes',
       'Files not touched in this PR but whose coverage was affected:',
       build_all_changed_table(all_changed)].join("\n\n")
    end

    # Builds 'All Covered Files' section with the complete file table.
    #
    # @param files [Array<Hash>, nil] Full coverage file list
    # @return [String] Markdown section or empty string if no files
    #
    def all_files_section(files)
      return if files.nil? || files.empty?

      "### All Covered Files\n\n#{build_all_files_table(files)}"
    end

    # Builds report sections when no baseline comparison available.
    #
    # Shows group statistics and optionally all files.
    #
    # @param coverage_result [Hash] Coverage result with groups and files
    # @param include_all_files [Boolean] Whether to include all files table
    # @return [String] Markdown section(s)
    #
    def no_comparison_sections(coverage_result, include_all_files:)
      md = []
      groups = coverage_result['groups']
      if groups && !groups.empty?
        simple_groups = groups.map { |g| { 'name' => g['name'], 'current' => g['coverage'] } }
        md << "### By Group\n\n#{build_groups_table(simple_groups)}"
      end
      md << all_files_section(coverage_result['files']) if include_all_files

      result = md.join("\n\n")
      result.empty? ? nil : result
    end

    def run_url_link
      return if run_url.nil? || run_url.empty?

      "📋 [View report & artifacts](#{run_url})"
    end

    # --- Table builders ---

    # Builds markdown table header for group coverage statistics.
    #
    # @param has_baseline [Boolean] Whether to include delta column
    # @return [String] Markdown table header with pipes and separators
    #
    def groups_table_header(has_baseline)
      if has_baseline
        "| Group | Coverage | Δ |\n|-------|----------|---|\n"
      else
        "| Group | Coverage |\n|-------|----------|\n"
      end
    end

    # Builds markdown table row for group coverage statistics.
    #
    # @param group [Hash] Group data with name and current (and optional baseline/delta)
    # @param has_baseline [Boolean] Whether to include delta column
    # @return [String] Markdown table row
    #
    def groups_table_row(group, has_baseline)
      if has_baseline
        "| #{group['name']} | #{format('%.1f%%', group['current'])} | #{delta_indicator(group['delta'])} |"
      else
        "| #{group['name']} | #{format('%.1f%%', group['current'])} |"
      end
    end

    # Builds markdown table for changed files with coverage data.
    #
    # @param changed_files [Array<Hash>, nil] Files changed in PR with coverage
    # @return [String] Markdown table or empty string if no files
    #
    def build_changed_files_table(changed_files)
      return if changed_files.nil? || changed_files.empty?

      has_baseline = changed_files.any? { |f| f['baseline'] || f['delta'] }
      header = changed_files_table_header(has_baseline)
      rows = changed_files.map { |f| changed_files_table_row(f, has_baseline) }
      header + rows.join("\n")
    end

    # Builds markdown table header for changed files.
    #
    # @param has_baseline [Boolean] Whether to include delta column
    # @return [String] Markdown table header with pipes and separators
    #
    def changed_files_table_header(has_baseline)
      if has_baseline
        "| File | Coverage | Δ | Uncovered Lines |\n|------|----------|---|-----------------|\n"
      else
        "| File | Coverage | Uncovered Lines |\n|------|----------|-----------------|\n"
      end
    end

    # Builds markdown table row for a changed file.
    #
    # @param file [Hash] File data with path, current coverage, uncovered_lines
    # @param has_baseline [Boolean] Whether to include delta column
    # @return [String] Markdown table row
    #
    def changed_files_table_row(file, has_baseline)
      uncovered = format_uncovered_lines(file['uncovered_lines'])
      if has_baseline
        delta_str = file['baseline'].nil? ? 'new' : delta_indicator(file['delta'])
        "| #{file['path']} | #{format('%.1f%%', file['current'])} | #{delta_str} | #{uncovered} |"
      else
        "| #{file['path']} | #{format('%.1f%%', file['current'])} | #{uncovered} |"
      end
    end

    # Builds markdown table for files with coverage changes (not in PR changes).
    #
    # @param all_changed [Array<Hash>, nil] Files with coverage changes
    # @return [String] Markdown table or empty string if no files
    #
    def build_all_changed_table(all_changed)
      return if all_changed.nil? || all_changed.empty?

      header = "| File | Coverage | Δ |\n|------|----------|---|\n"
      rows = all_changed.map do |f|
        "| #{f['path']} | #{format('%.1f%%', f['current'])} | #{delta_indicator(f['delta'])} |"
      end
      header + rows.join("\n")
    end

    # Builds markdown table for all covered files with line statistics.
    #
    # @param files [Array<Hash>, nil] Files with coverage data and uncovered line numbers
    # @return [String] Markdown table or empty string if no files
    #
    def build_all_files_table(files)
      return if files.nil? || files.empty?

      has_baseline = files.any? do |f|
        !((f['baseline'] || f[:baseline]).nil? && (f['delta'] || f[:delta]).nil?)
      end

      header = if has_baseline
                 "| File | Coverage | Δ | Covered / Total | Uncovered Lines |\n" \
                 "|------|----------|---|-----------------|-----------------|\n"
               else
                 "| File | Coverage | Covered / Total | Uncovered Lines |\n" \
                 "|------|----------|-----------------|-----------------|\n"
               end

      rows = files.map { |f| all_files_table_row(f, has_baseline) }
      header + rows.join("\n")
    end

    # Builds markdown table row for all files table.
    #
    # @param file [Hash] File data with path, coverage, covered_lines, total_lines, uncovered_lines
    # @return [String] Markdown table row
    #
    def all_files_table_row(file, has_baseline)
      uncovered = format_uncovered_lines(file['uncovered_lines'] || file[:uncovered_lines])
      coverage = file['coverage'] || file[:coverage]
      covered_lines = file['covered_lines'] || file[:covered_lines]
      total_lines = file['total_lines'] || file[:total_lines]
      path = file['path'] || file[:path]
      if has_baseline
        baseline = file['baseline'] || file[:baseline]
        delta = file['delta'] || file[:delta]
        delta_str = baseline.nil? && delta.nil? ? 'new' : delta_indicator(delta)
        "| #{path} | #{format('%.1f%%', coverage)} | #{delta_str} | #{covered_lines} / #{total_lines} | #{uncovered} |"
      else
        "| #{path} | #{format('%.1f%%', coverage)} | #{covered_lines} / #{total_lines} | #{uncovered} |"
      end
    end

    # --- Consecutive line grouping ---

    # Groups sorted line numbers into consecutive ranges.
    #
    # @param sorted_lines [Array<Integer>] Sorted array of line numbers
    # @return [Array<Array<Integer>>] Array of ranges, each range is an array of consecutive lines
    #
    def group_consecutive(sorted_lines)
      ranges = []
      current_range = nil

      sorted_lines.each do |line|
        if current_range && line == current_range.last + 1
          current_range << line
        else
          ranges << current_range if current_range
          current_range = [line]
        end
      end
      ranges << current_range if current_range
      ranges
    end

    # Converts uncovered line numbers to GitHub Check Run annotations.
    #
    # Groups consecutive lines into single annotations with range messages.
    #
    # @param file_path [String] File path for annotation
    # @param uncovered_lines [Array<Integer>] 1-based line numbers of uncovered lines
    # @return [Array<Hash>] Annotation objects with path, line ranges, and messages
    #
    def ranges_to_annotations(file_path, uncovered_lines)
      ranges = []
      current_range = nil

      uncovered_lines.sort.each do |line|
        if current_range && line == current_range[:end] + 1
          current_range[:end] = line
        else
          ranges << current_range if current_range
          current_range = { start: line, end: line }
        end
      end
      ranges << current_range if current_range

      ranges.map { |range| build_annotation(file_path, range) }
    end

    # Builds a single GitHub Check Run annotation object.
    #
    # @param file_path [String] File path for annotation
    # @param range [Hash] Range with start and end line numbers
    # @return [Hash] Annotation with path, line range, level, and message
    #
    def build_annotation(file_path, range)
      message = if range[:start] == range[:end]
                  "Line #{range[:start]} is not covered by tests"
                else
                  "Lines #{range[:start]}-#{range[:end]} are not covered by tests"
                end

      { path: file_path, start_line: range[:start], end_line: range[:end],
        annotation_level: 'warning', message: message }
    end

    # --- GitHub API ---

    # Initializes and returns cached Octokit client with GitHub credentials.
    #
    # @return [Octokit::Client] GitHub API client with auto-pagination enabled
    #
    def github_client
      @github_client ||= Octokit::Client.new(access_token: token, api_endpoint: api_url, auto_paginate: true)
    end

    # Creates GitHub check run with annotations and handles annotation pagination.
    #
    # Creates check run with first batch of annotations, then submits remaining batches separately
    # due to API limits. Logs warning if API call fails.
    #
    # @param annotations [Array<Hash>] Check run annotations with uncovered line info
    # @param coverage_result [Hash] Coverage result with total_coverage
    # @param comparison [Hash, nil] Comparison data for conclusion determination
    def create_check_run(annotations, coverage_result, comparison)
      conclusion = determine_conclusion(coverage_result, comparison)
      summary = check_run_summary(coverage_result, comparison)
      check_annotations = filter_annotations(annotations)

      check_run_id = submit_check_run(check_name, sha, conclusion, summary, check_annotations)
      submit_remaining_annotations(check_run_id, summary, check_annotations)
    rescue Octokit::Error => e
      warn "Warning: Failed to create/update check run: #{e.message}"
    end

    # Determines check run conclusion based on coverage thresholds and comparison.
    #
    # Returns 'neutral' if below MIN_COVERAGE or coverage decreased, 'success' otherwise.
    #
    # @param coverage_result [Hash] Coverage result with total_coverage
    # @param comparison [Hash, nil] Comparison data with overall delta
    # @return [String] Check run conclusion: 'success' or 'neutral'
    #
    def determine_conclusion(coverage_result, comparison)
      total_coverage = coverage_result['total_coverage']

      if total_coverage < min_coverage || (comparison && comparison['overall']['delta']&.negative?)
        'neutral'
      else
        'success'
      end
    end

    # Builds summary text for check run output.
    #
    # @param coverage_result [Hash] Coverage result with total_coverage
    # @param comparison [Hash, nil] Comparison data with overall delta
    # @return [String] Summary text with coverage and optional delta
    #
    def check_run_summary(coverage_result, comparison)
      overall_pct = format('%.1f%%', coverage_result['total_coverage'])
      if comparison
        delta_str = format('%+.2f%%', comparison['overall']['delta'])
        "Coverage: #{overall_pct} (#{delta_str} vs baseline)"
      else
        "Coverage: #{overall_pct}"
      end
    end

    # Filters annotations based on ANNOTATIONS environment variable.
    #
    # @param annotations [Array<Hash>] All annotations to potentially filter
    # @return [Array<Hash>] Annotations if ANNOTATIONS='true', empty array otherwise
    #
    def filter_annotations(annotations)
      annotations_enabled? ? annotations : []
    end

    # Creates initial GitHub check run with first batch of annotations.
    #
    # Due to API limits, only first 50 annotations are included. Remaining batches
    # are added separately via submit_remaining_annotations.
    #
    # @param check_name [String] Name for the check run
    # @param sha [String] Git commit SHA
    # @param conclusion [String] Check run conclusion ('success' or 'neutral')
    # @param summary [String] Check run summary text
    # @param check_annotations [Array<Hash>] All annotations (may exceed API limit)
    # @return [Integer] Check run ID
    #
    def submit_check_run(check_name, sha, conclusion, summary, check_annotations)
      first_batch = check_annotations.first(MAX_ANNOTATIONS_PER_CALL)

      check_run = github_client.create_check_run(
        repository, check_name, sha,
        status: 'completed', conclusion: conclusion,
        output: { title: summary, summary: summary, annotations: first_batch }
      )

      puts "Created check run ##{check_run.id}: #{conclusion}"
      check_run.id
    end

    # Submits remaining annotations to check run beyond first batch.
    #
    # Handles pagination by submitting annotations in batches of MAX_ANNOTATIONS_PER_CALL.
    #
    # @param check_run_id [Integer] ID of check run to update
    # @param summary [String] Check run summary text
    # @param check_annotations [Array<Hash>] All annotations (used to count total)
    def submit_remaining_annotations(check_run_id, summary, check_annotations)
      remaining = check_annotations.drop(MAX_ANNOTATIONS_PER_CALL)

      while remaining.any?
        batch = remaining.first(MAX_ANNOTATIONS_PER_CALL)
        remaining = remaining.drop(MAX_ANNOTATIONS_PER_CALL)

        github_client.update_check_run(
          repository, check_run_id,
          output: { title: summary, summary: summary, annotations: batch }
        )
      end

      puts "Added #{check_annotations.size} annotation(s) to check run"
    end

    # Posts new PR comment or updates existing coverage report comment.
    #
    # Searches for existing comment with COMMENT_MARKER and updates it if found,
    # otherwise creates new comment. Skips if POST_COMMENT='false'.
    #
    # @param comment_body [String] Markdown content for PR comment
    def post_or_update_pr_comment(comment_body)
      return unless post_comment_enabled?

      pr_number = current_pr_number
      return unless pr_number

      existing = find_existing_comment(pr_number)
      if existing
        github_client.update_comment(repository, existing.id, comment_body)
        return puts "Updated existing PR comment ##{existing.id}"
      end

      github_client.add_comment(repository, pr_number, comment_body)
      puts 'Created new PR comment'
    end

    # Extracts PR number from GitHub Actions event.json.
    #
    # @return [Integer, nil] PR number if in PR context, nil otherwise
    #
    def current_pr_number
      return nil unless event_path && File.exist?(event_path)

      event = JSON.parse(File.read(event_path))
      event.dig('pull_request', 'number')
    end

    # Finds existing PR comment with coverage report marker.
    #
    # @param pr_number [Integer] PR number
    # @return [Octokit::Comment, nil] Existing comment if found, nil otherwise
    #
    def find_existing_comment(pr_number)
      comments = github_client.issue_comments(repository, pr_number)
      comments.find { |c| c.body&.include?(COMMENT_MARKER) }
    end

    # Writes markdown job summary to GitHub Actions summary file.
    #
    # Appends to GITHUB_STEP_SUMMARY if available. Logs message if env var not set.
    #
    # @param markdown [String] Markdown content to write
    def write_job_summary(markdown)
      if step_summary_path && !step_summary_path.empty?
        File.open(step_summary_path, 'a') { |f| f.write(markdown) }
        puts "Wrote job summary to #{step_summary_path}"
      else
        puts 'GITHUB_STEP_SUMMARY not set — skipping job summary'
      end
    end
  end
end

SimpleCovDelta::Report.new.run if __FILE__ == $PROGRAM_NAME

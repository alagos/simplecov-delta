# frozen_string_literal: true

require 'json'
require 'octokit'

# Phase 3: Reporting
# Creates Check Run annotations, writes Job Summary, and posts/updates PR comment.

module SimpleCovDelta
  module Report
    COMMENT_MARKER = '<!-- simplecov-delta -->'
    MAX_ANNOTATIONS_PER_CALL = 50

    module_function

    def github_client
      @github_client ||= begin
        token = ENV.fetch('GITHUB_TOKEN', '')
        api_url = ENV.fetch('GITHUB_API_URL', 'https://api.github.com')
        Octokit::Client.new(access_token: token, api_endpoint: api_url, auto_paginate: true)
      end
    end

    def delta_indicator(delta)
      return '—' if delta.nil?

      formatted = format('%+.1f%%', delta)
      if delta.positive?
        "#{formatted} ✅"
      elsif delta.negative?
        "#{formatted} ⚠️"
      else
        formatted
      end
    end

    def format_uncovered_lines(lines)
      return '—' if lines.nil? || lines.empty?

      # Group consecutive lines into ranges
      ranges = []
      current_range = nil

      lines.sort.each do |line|
        if current_range && line == current_range.last + 1
          current_range << line
        else
          ranges << current_range if current_range
          current_range = [line]
        end
      end
      ranges << current_range if current_range

      ranges.map do |range|
        range.size == 1 ? range.first.to_s : "#{range.first}-#{range.last}"
      end.join(', ')
    end

    def build_groups_table(groups)
      return '' if groups.nil? || groups.empty?

      has_baseline = groups.any? { |g| g['baseline'] || g['delta'] }

      header = if has_baseline
                 "| Group | Coverage | Δ |\n|-------|----------|---|\n"
               else
                 "| Group | Coverage |\n|-------|----------|\n"
               end

      rows = groups.map do |g|
        if has_baseline
          delta_str = delta_indicator(g['delta'])
          "| #{g['name']} | #{format('%.1f%%', g['current'])} | #{delta_str} |"
        else
          "| #{g['name']} | #{format('%.1f%%', g['current'])} |"
        end
      end

      header + rows.join("\n")
    end

    def build_changed_files_table(changed_files)
      return '' if changed_files.nil? || changed_files.empty?

      has_baseline = changed_files.any? { |f| f['baseline'] || f['delta'] }

      header = if has_baseline
                 "| File | Coverage | Δ | Uncovered Lines |\n|------|----------|---|------------------|\n"
               else
                 "| File | Coverage | Uncovered Lines |\n|------|----------|------------------|\n"
               end

      rows = changed_files.map do |f|
        uncovered = format_uncovered_lines(f['uncovered_lines'])
        if has_baseline
          delta_str = f['baseline'].nil? ? 'new' : delta_indicator(f['delta'])
          "| #{f['path']} | #{format('%.1f%%', f['current'])} | #{delta_str} | #{uncovered} |"
        else
          "| #{f['path']} | #{format('%.1f%%', f['current'])} | #{uncovered} |"
        end
      end

      header + rows.join("\n")
    end

    def build_all_changed_table(all_changed)
      return '' if all_changed.nil? || all_changed.empty?

      header = "| File | Coverage | Δ |\n|------|----------|---|\n"
      rows = all_changed.map do |f|
        "| #{f['path']} | #{format('%.1f%%', f['current'])} | #{delta_indicator(f['delta'])} |"
      end

      header + rows.join("\n")
    end

    def build_pr_comment(coverage_result, comparison, run_url)
      overall_pct = format('%.1f%%', coverage_result['total_coverage'])

      md = +"#{COMMENT_MARKER}\n"
      md << "## 📊 Coverage Report\n\n"

      if comparison
        overall = comparison['overall']
        delta_str = delta_indicator(overall['delta'])
        md << "**Overall: #{overall_pct}** (#{delta_str} vs baseline)\n\n"
      else
        md << "**Overall: #{overall_pct}**\n\n"
      end

      if comparison
        groups = comparison['groups']
        if groups && !groups.empty?
          md << "### By Group\n\n"
          md << build_groups_table(groups)
          md << "\n\n"
        end

        changed = comparison['changed_files']
        if changed && !changed.empty?
          md << "### Changed Files\n\n"
          md << build_changed_files_table(changed)
          md << "\n\n"
        end
      else
        groups = coverage_result['groups']
        if groups && !groups.empty?
          md << "### By Group\n\n"
          simple_groups = groups.map { |g| { 'name' => g['name'], 'current' => g['coverage'] } }
          md << build_groups_table(simple_groups)
          md << "\n\n"
        end
      end

      md << "📋 [Full coverage details](#{run_url})" if run_url && !run_url.empty?
      md
    end

    def build_job_summary(coverage_result, comparison, run_url)
      overall_pct = format('%.1f%%', coverage_result['total_coverage'])

      md = +"## 📊 Coverage Report — Full Details\n\n"

      if comparison
        overall = comparison['overall']
        delta_str = delta_indicator(overall['delta'])
        md << "**Overall: #{overall_pct}** (#{delta_str} vs baseline)\n\n"
      else
        md << "**Overall: #{overall_pct}**\n\n"
      end

      if comparison
        groups = comparison['groups']
        if groups && !groups.empty?
          md << "### By Group\n\n"
          md << build_groups_table(groups)
          md << "\n\n"
        end

        changed = comparison['changed_files']
        if changed && !changed.empty?
          md << "### Changed Files\n\n"
          md << build_changed_files_table(changed)
          md << "\n\n"
        end

        all_changed = comparison['all_changed_coverage_files']
        if all_changed && !all_changed.empty?
          md << "### All Files with Coverage Changes\n\n"
          md << "Files not touched in this PR but whose coverage was affected:\n\n"
          md << build_all_changed_table(all_changed)
          md << "\n\n"
        end
      else
        groups = coverage_result['groups']
        if groups && !groups.empty?
          md << "### By Group\n\n"
          simple_groups = groups.map { |g| { 'name' => g['name'], 'current' => g['coverage'] } }
          md << build_groups_table(simple_groups)
          md << "\n\n"
        end
      end

      md
    end

    def build_annotations(comparison)
      return [] unless comparison

      annotations = []
      changed_files = comparison['changed_files'] || []

      changed_files.each do |file|
        uncovered = file['uncovered_lines'] || []
        next if uncovered.empty?

        # Group consecutive lines into ranges for batch annotations
        ranges = []
        current_range = nil

        uncovered.sort.each do |line|
          if current_range && line == current_range[:end] + 1
            current_range[:end] = line
          else
            ranges << current_range if current_range
            current_range = { start: line, end: line }
          end
        end
        ranges << current_range if current_range

        ranges.each do |range|
          message = if range[:start] == range[:end]
                      "Line #{range[:start]} is not covered by tests"
                    else
                      "Lines #{range[:start]}-#{range[:end]} are not covered by tests"
                    end

          annotations << {
            path: file['path'],
            start_line: range[:start],
            end_line: range[:end],
            annotation_level: 'warning',
            message: message
          }
        end
      end

      annotations
    end

    def create_check_run(annotations, coverage_result, comparison)
      repository = ENV.fetch('GITHUB_REPOSITORY', '')
      sha = ENV.fetch('GITHUB_SHA', '')
      check_name = ENV.fetch('CHECK_NAME', 'Coverage Report')
      min_coverage = ENV.fetch('MIN_COVERAGE', '0').to_f
      enable_annotations = ENV.fetch('ANNOTATIONS', 'true') == 'true'

      total_coverage = coverage_result['total_coverage']

      # Determine conclusion
      conclusion = if total_coverage < min_coverage
                     'neutral'
                   elsif comparison && comparison['overall']['delta']&.negative?
                     'neutral'
                   else
                     'success'
                   end

      overall_pct = format('%.1f%%', total_coverage)
      summary = if comparison
                  delta_str = format('%+.1f%%', comparison['overall']['delta'])
                  "Coverage: #{overall_pct} (#{delta_str} vs baseline)"
                else
                  "Coverage: #{overall_pct}"
                end

      # Filter annotations if disabled
      check_annotations = enable_annotations ? annotations : []

      # Create the check run with first batch of annotations (max 50)
      first_batch = check_annotations.first(MAX_ANNOTATIONS_PER_CALL)
      remaining = check_annotations.drop(MAX_ANNOTATIONS_PER_CALL)

      check_run = github_client.create_check_run(
        repository,
        check_name,
        sha,
        status: 'completed',
        conclusion: conclusion,
        output: {
          title: summary,
          summary: summary,
          annotations: first_batch
        }
      )

      check_run_id = check_run.id
      puts "Created check run ##{check_run_id}: #{conclusion}"

      # Send remaining annotations in batches
      while remaining.any?
        batch = remaining.first(MAX_ANNOTATIONS_PER_CALL)
        remaining = remaining.drop(MAX_ANNOTATIONS_PER_CALL)

        github_client.update_check_run(
          repository,
          check_run_id,
          output: {
            title: summary,
            summary: summary,
            annotations: batch
          }
        )
      end

      total_annotations = check_annotations.size
      puts "Added #{total_annotations} annotation(s) to check run"
    rescue Octokit::Error => e
      warn "Warning: Failed to create/update check run: #{e.message}"
    end

    def post_or_update_pr_comment(comment_body)
      return unless ENV.fetch('POST_COMMENT', 'true') == 'true'

      event_path = ENV['GITHUB_EVENT_PATH']
      return unless event_path && File.exist?(event_path)

      event = JSON.parse(File.read(event_path))
      pr_number = event.dig('pull_request', 'number')
      return unless pr_number

      repository = ENV.fetch('GITHUB_REPOSITORY', '')

      # Find existing comment with our marker
      comments = github_client.issue_comments(repository, pr_number)
      existing = comments.find { |c| c.body&.include?(COMMENT_MARKER) }

      if existing
        github_client.update_comment(repository, existing.id, comment_body)
        puts "Updated existing PR comment ##{existing.id}"
      else
        github_client.add_comment(repository, pr_number, comment_body)
        puts 'Created new PR comment'
      end
    rescue Octokit::Error => e
      warn "Warning: Failed to post/update PR comment: #{e.message}"
    end

    def write_job_summary(markdown)
      summary_path = ENV['GITHUB_STEP_SUMMARY']
      if summary_path
        File.open(summary_path, 'a') { |f| f.write(markdown) }
        puts "Wrote job summary to #{summary_path}"
      else
        puts 'GITHUB_STEP_SUMMARY not set — skipping job summary'
      end
    end

    def run
      coverage_path = ENV.fetch('COVERAGE_PATH', 'coverage')
      server_url = ENV.fetch('GITHUB_SERVER_URL', 'https://github.com')
      repository = ENV.fetch('GITHUB_REPOSITORY', '')
      run_id = ENV.fetch('GITHUB_RUN_ID', '')
      run_url = "#{server_url}/#{repository}/actions/runs/#{run_id}"

      # Load coverage result
      result_path = File.join(coverage_path, 'coverage_result.json')
      abort "Error: Coverage result not found at #{result_path}" unless File.exist?(result_path)
      coverage_result = JSON.parse(File.read(result_path))

      # Load comparison (if exists)
      comparison_path = File.join(coverage_path, 'comparison.json')
      comparison = File.exist?(comparison_path) ? JSON.parse(File.read(comparison_path)) : nil

      # Build annotations
      annotations = build_annotations(comparison)
      puts "Built #{annotations.size} annotation(s)"

      # Create Check Run
      create_check_run(annotations, coverage_result, comparison)

      # Build and write Job Summary
      summary_md = build_job_summary(coverage_result, comparison, run_url)
      write_job_summary(summary_md)

      # Build and post/update PR comment
      comment_md = build_pr_comment(coverage_result, comparison, run_url)
      post_or_update_pr_comment(comment_md)

      puts 'Reporting complete!'
    end
  end
end

SimpleCovDelta::Report.run if __FILE__ == $PROGRAM_NAME

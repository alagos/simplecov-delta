# frozen_string_literal: true

require 'json'
require 'octokit'

# Phase 2: Comparison
# Compares the current merged .resultset.json against a baseline and computes:
# - Overall coverage delta
# - Per-group coverage delta
# - Per-file coverage delta
# - Uncovered lines in changed files

module SimpleCovDelta
  module Compare
    module_function

    # Parse a .resultset.json and return a normalized hash of { relative_path => { lines: [...] } }
    def parse_resultset(path)
      data = JSON.parse(File.read(path))
      files = {}

      data.each_value do |command_data|
        coverage = command_data['coverage'] || {}
        coverage.each do |file_path, file_data|
          relative = normalize_path(file_path)
          lines = file_data.is_a?(Hash) ? (file_data['lines'] || []) : file_data

          if files[relative]
            # Merge lines by summing hit counts
            existing = files[relative][:lines]
            lines.each_with_index do |count, i|
              next if count.nil?

              if existing[i].nil?
                existing[i] = count
              else
                existing[i] += count
              end
            end
          else
            files[relative] = { lines: lines.dup }
          end
        end
      end

      files
    end

    # Strip absolute path prefix to get a relative path
    def normalize_path(absolute_path)
      # Common CI path prefixes to strip
      prefixes = [
        %r{^/home/runner/work/[^/]+/[^/]+/},
        %r{^/github/workspace/},
        %r{^/app/},
        %r{^/}
      ]

      path = absolute_path
      prefixes.each do |prefix|
        if path.match?(prefix)
          path = path.sub(prefix, '')
          break
        end
      end
      path
    end

    # Compute coverage stats for a file's line array
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

    # Find uncovered line numbers (0 hit count)
    def uncovered_lines(lines)
      result = []
      lines.each_with_index do |count, i|
        result << (i + 1) if !count.nil? && count.zero? # line numbers are 1-based
      end
      result
    end

    # Fetch changed files from the GitHub PR API
    def fetch_changed_files
      event_path = ENV['GITHUB_EVENT_PATH']
      return [] unless event_path && File.exist?(event_path)

      event = JSON.parse(File.read(event_path))
      pr_number = event.dig('pull_request', 'number')
      return [] unless pr_number

      repository = ENV['GITHUB_REPOSITORY']
      token = ENV['GITHUB_TOKEN']
      api_url = ENV.fetch('GITHUB_API_URL', 'https://api.github.com')

      client = Octokit::Client.new(access_token: token, api_endpoint: api_url, auto_paginate: true)
      files = client.pull_request_files(repository, pr_number)
      files.map(&:filename)
    rescue Octokit::Error => e
      warn "Warning: Failed to fetch PR files: #{e.message}"
      []
    end

    # Compute per-group coverage from a file hash
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

    # Main comparison logic
    def run
      coverage_path = ENV.fetch('COVERAGE_PATH', 'coverage')
      baseline_path = ENV.fetch('BASELINE_PATH', '')
      groups_input = ENV.fetch('SIMPLECOV_GROUPS', '').split("\n").map(&:strip).reject(&:empty?)

      current_resultset = File.join(coverage_path, '.resultset.json')
      abort "Error: Current resultset not found at #{current_resultset}" unless File.exist?(current_resultset)

      unless File.exist?(baseline_path)
        puts 'No baseline file found — skipping comparison.'
        return
      end

      puts "Comparing #{current_resultset} against #{baseline_path}..."

      current_files = parse_resultset(current_resultset)
      baseline_files = parse_resultset(baseline_path)

      # Overall coverage
      current_total = 0
      current_covered = 0
      current_files.each_value do |data|
        stats = file_coverage(data[:lines])
        current_total += stats[:total]
        current_covered += stats[:covered]
      end
      current_overall = current_total.positive? ? (current_covered.to_f / current_total * 100).round(2) : 0.0

      baseline_total = 0
      baseline_covered = 0
      baseline_files.each_value do |data|
        stats = file_coverage(data[:lines])
        baseline_total += stats[:total]
        baseline_covered += stats[:covered]
      end
      baseline_overall = baseline_total.positive? ? (baseline_covered.to_f / baseline_total * 100).round(2) : 0.0

      overall_delta = (current_overall - baseline_overall).round(2)

      # Parse group definitions
      group_definitions = groups_input.map do |group_def|
        name, path = group_def.split(':', 2)
        { name: name.strip, path: path.strip }
      end

      # Per-group coverage
      current_groups = group_coverage(current_files, group_definitions)
      baseline_groups = group_coverage(baseline_files, group_definitions)

      group_results = current_groups.map do |cg|
        bg = baseline_groups.find { |g| g[:name] == cg[:name] }
        baseline_pct = bg ? bg[:coverage] : nil
        delta = baseline_pct ? (cg[:coverage] - baseline_pct).round(2) : nil
        { name: cg[:name], current: cg[:coverage], baseline: baseline_pct, delta: delta }
      end

      # Fetch changed files from PR
      changed_files_list = fetch_changed_files
      puts "Changed files in PR: #{changed_files_list.size}"

      # Per-file comparison for changed files
      changed_file_results = changed_files_list.filter_map do |changed_path|
        current_data = current_files[changed_path]
        baseline_data = baseline_files[changed_path]

        next unless current_data # file not in coverage results

        current_stats = file_coverage(current_data[:lines])
        uncovered = uncovered_lines(current_data[:lines])

        if baseline_data
          baseline_stats = file_coverage(baseline_data[:lines])
          delta = (current_stats[:percentage] - baseline_stats[:percentage]).round(2)
          {
            path: changed_path,
            current: current_stats[:percentage],
            baseline: baseline_stats[:percentage],
            delta: delta,
            uncovered_lines: uncovered
          }
        else
          {
            path: changed_path,
            current: current_stats[:percentage],
            baseline: nil,
            delta: nil,
            uncovered_lines: uncovered
          }
        end
      end

      # All files with coverage changes (not just PR-changed files)
      all_changed_coverage = []
      all_paths = (current_files.keys + baseline_files.keys).uniq

      all_paths.each do |path|
        current_data = current_files[path]
        baseline_data = baseline_files[path]

        current_pct = current_data ? file_coverage(current_data[:lines])[:percentage] : 0.0
        baseline_pct = baseline_data ? file_coverage(baseline_data[:lines])[:percentage] : 0.0
        delta = (current_pct - baseline_pct).round(2)

        next if delta.zero?
        next if changed_files_list.include?(path) # already in changed_files

        all_changed_coverage << {
          path: path,
          current: current_pct,
          baseline: baseline_pct,
          delta: delta
        }
      end

      # Sort by absolute delta descending
      all_changed_coverage.sort_by! { |f| -f[:delta].abs }

      # Build comparison result
      comparison = {
        overall: {
          current: current_overall,
          baseline: baseline_overall,
          delta: overall_delta
        },
        groups: group_results,
        changed_files: changed_file_results,
        all_changed_coverage_files: all_changed_coverage
      }

      output_path = File.join(coverage_path, 'comparison.json')
      File.write(output_path, JSON.pretty_generate(comparison))

      puts "\nComparison complete!"
      puts "  Current: #{current_overall}%"
      puts "  Baseline: #{baseline_overall}%"
      puts "  Delta: #{overall_delta >= 0 ? '+' : ''}#{overall_delta}%"
      puts "  Changed files analyzed: #{changed_file_results.size}"
      puts "  Other files with coverage changes: #{all_changed_coverage.size}"
      puts "  Output: #{output_path}"
    end
  end
end

SimpleCovDelta::Compare.run if __FILE__ == $PROGRAM_NAME

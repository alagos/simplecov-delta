# frozen_string_literal: true

require 'simplecov'
require 'json'

# Phase 1: Collation
# Merges all .resultset.json files into a single SimpleCov result and produces:
# - Merged .resultset.json
# - Merged HTML report (index.html + assets/)
# - coverage_result.json with total coverage metadata

coverage_path = ENV.fetch('COVERAGE_PATH', 'coverage')
resultset_patterns = ENV.fetch('RESULTSET_PATHS', '').split("\n").map(&:strip).reject(&:empty?)
profile = ENV.fetch('SIMPLECOV_PROFILE', 'rails')
filters = ENV.fetch('SIMPLECOV_FILTERS', '').split("\n").map(&:strip).reject(&:empty?)
groups = ENV.fetch('SIMPLECOV_GROUPS', '').split("\n").map(&:strip).reject(&:empty?)

# Resolve glob patterns to actual files
resultset_files = resultset_patterns.flat_map { |pattern| Dir.glob(pattern) }.uniq

if resultset_files.empty?
  abort "Error: No .resultset.json files found matching patterns: #{resultset_patterns.join(', ')}"
end

puts "Found #{resultset_files.size} resultset file(s):"
resultset_files.each { |f| puts "  - #{f}" }

# Configure SimpleCov output
SimpleCov.coverage_dir(coverage_path)

# Configure formatters — HTML report + merged .resultset.json
SimpleCov.formatters = SimpleCov::Formatter::MultiFormatter.new([SimpleCov::Formatter::HTMLFormatter])

# Collate all resultset files
SimpleCov.collate(resultset_files, profile) do
  # Apply filters
  filters.each do |filter_regex|
    add_filter Regexp.new(filter_regex)
  end

  # Apply groups
  groups.each do |group_def|
    name, path = group_def.split(':', 2)
    add_group(name.strip, path.strip) if name && path
  end
end

# Read back the merged result to extract total coverage
merged_resultset_path = File.join(coverage_path, '.resultset.json')
abort "Error: Merged .resultset.json not found at #{merged_resultset_path}" unless File.exist?(merged_resultset_path)

merged_data = JSON.parse(File.read(merged_resultset_path))

# Calculate total coverage from the merged result
total_lines = 0
covered_lines = 0

merged_data.each_value do |command_data|
  coverage = command_data['coverage'] || {}
  coverage.each_value do |file_data|
    lines = file_data.is_a?(Hash) ? (file_data['lines'] || []) : file_data
    lines.each do |hit_count|
      next if hit_count.nil? # non-executable line

      total_lines += 1
      covered_lines += 1 if hit_count.positive?
    end
  end
end

total_coverage = total_lines.positive? ? (covered_lines.to_f / total_lines * 100).round(2) : 0.0

# Also compute per-group coverage
group_coverages = []
group_definitions = groups.map do |group_def|
  name, path = group_def.split(':', 2)
  { name: name.strip, path: path.strip }
end

if group_definitions.any?
  merged_data.each_value do |command_data|
    coverage = command_data['coverage'] || {}

    group_definitions.each do |group_def|
      group_total = 0
      group_covered = 0

      coverage.each do |file_path, file_data|
        # Check if file belongs to this group (path match)
        next unless file_path.include?(group_def[:path])

        lines = file_data.is_a?(Hash) ? (file_data['lines'] || []) : file_data
        lines.each do |hit_count|
          next if hit_count.nil?

          group_total += 1
          group_covered += 1 if hit_count.positive?
        end
      end

      next unless group_total.positive?

      existing = group_coverages.find { |g| g[:name] == group_def[:name] }
      if existing
        existing[:total_lines] += group_total
        existing[:covered_lines] += group_covered
      else
        group_coverages << {
          name: group_def[:name],
          total_lines: group_total,
          covered_lines: group_covered
        }
      end
    end
  end
end

# Write coverage metadata for use by compare and report phases
coverage_result = {
  total_coverage: total_coverage,
  total_lines: total_lines,
  covered_lines: covered_lines,
  groups: group_coverages.map do |g|
    pct = g[:total_lines].positive? ? (g[:covered_lines].to_f / g[:total_lines] * 100).round(2) : 0.0
    { name: g[:name], coverage: pct, total_lines: g[:total_lines], covered_lines: g[:covered_lines] }
  end
}

result_path = File.join(coverage_path, 'coverage_result.json')
File.write(result_path, JSON.pretty_generate(coverage_result))

puts "\nCollation complete!"
puts "  Total coverage: #{total_coverage}%"
puts "  Total lines: #{total_lines}"
puts "  Covered lines: #{covered_lines}"
coverage_result[:groups].each do |g|
  puts "  #{g[:name]}: #{g[:coverage]}%"
end
puts "  Merged resultset: #{merged_resultset_path}"
puts "  Coverage result: #{result_path}"

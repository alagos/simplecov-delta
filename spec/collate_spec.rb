# frozen_string_literal: true

require 'spec_helper'
require_relative '../scripts/collate'

# Test the collation script's file-finding and coverage calculation logic
# without actually running SimpleCov.collate (which requires a full SimpleCov setup)
RSpec.describe SimpleCovDelta::Collate do
  subject(:collate) { described_class.new }

  around do |example|
    original = ENV.to_h
    begin
      example.run
    ensure
      ENV.replace(original)
    end
  end

  describe 'resultset file discovery' do
    it 'finds resultset files matching glob patterns' do
      patterns = [fixture_path('resultset_*.json')]
      files = patterns.flat_map { |p| Dir.glob(p) }.uniq

      expect(files.size).to eq(2)
      expect(files.all? { |f| File.exist?(f) }).to be true
    end

    it 'handles multiple patterns' do
      patterns = [
        fixture_path('resultset_1.json'),
        fixture_path('resultset_2.json')
      ]
      files = patterns.flat_map { |p| Dir.glob(p) }.uniq

      expect(files.size).to eq(2)
    end

    it 'deduplicates files' do
      patterns = [
        fixture_path('resultset_*.json'),
        fixture_path('resultset_1.json')
      ]
      files = patterns.flat_map { |p| Dir.glob(p) }.uniq

      expect(files.size).to eq(2)
    end
  end

  describe 'coverage calculation from resultset' do
    let(:resultset) { JSON.parse(File.read(fixture_path('merged_resultset.json'))) }

    it 'computes total coverage' do
      total_lines = 0
      covered_lines = 0

      resultset.each do |_command_name, command_data|
        coverage = command_data['coverage'] || {}
        coverage.each do |_file_path, file_data|
          lines = file_data.is_a?(Hash) ? (file_data['lines'] || []) : file_data
          lines.each do |hit_count|
            next if hit_count.nil?

            total_lines += 1
            covered_lines += 1 if hit_count.positive?
          end
        end
      end

      percentage = (covered_lines.to_f / total_lines * 100).round(2)

      # merged_resultset.json has:
      # user.rb: [1,1,nil,1,1,nil,1,1,1,nil] -> 7/7
      # auth_service.rb: [1,1,1,0,0,nil,1,1,0,nil] -> 5/8
      # account.rb: [1,1,1,nil,1,1,nil,0,0,nil] -> 5/7
      # user_type.rb: [1,1,1,nil,0,0,nil] -> 3/5
      # Total: 20/27 = 74.07%
      expect(total_lines).to eq(27)
      expect(covered_lines).to eq(20)
      expect(percentage).to eq(74.07)
    end
  end

  describe 'group definitions parsing' do
    it 'parses name:path pairs' do
      groups_input = "Models:app/models\nServices:app/services\nGraphQL:app/graphql"
      groups = groups_input.split("\n").map(&:strip).reject(&:empty?)

      parsed = groups.map do |group_def|
        name, path = group_def.split(':', 2)
        { name: name.strip, path: path.strip }
      end

      expect(parsed.size).to eq(3)
      expect(parsed[0]).to eq({ name: 'Models', path: 'app/models' })
      expect(parsed[1]).to eq({ name: 'Services', path: 'app/services' })
      expect(parsed[2]).to eq({ name: 'GraphQL', path: 'app/graphql' })
    end
  end

  describe 'private behavior' do
    def stub_simplecov_collate_with(fake_config)
      allow(SimpleCov).to receive(:coverage_dir)
      allow(SimpleCov).to receive(:formatters=)
      allow(SimpleCov).to receive(:collate) do |_files, _profile, &block|
        fake_config.instance_exec(&block)
      end
    end

    it 'finds resultset files via configured patterns' do
      ENV['RESULTSET_PATHS'] = "#{fixture_path('resultset_1.json')}\n#{fixture_path('resultset_2.json')}"
      files = collate.send(:find_resultset_files)

      expect(files.size).to eq(2)
    end

    it 'aborts when no resultset files are found' do
      ENV['RESULTSET_PATHS'] = 'does/not/exist/*.json'

      expect { collate.send(:find_resultset_files) }.to raise_error(SystemExit)
    end

    it 'merges line counts and extends arrays' do
      existing = [1, nil, 2]
      lines = [2, 1, nil, 4]

      collate.send(:merge_lines!, existing, lines)

      expect(existing).to eq([3, 1, 2, 4])
    end

    it 'normalizes github workspace paths' do
      ENV['GITHUB_WORKSPACE'] = '/repo'

      result = collate.send(:normalize_path, '/github/workspace/app/models/user.rb')
      expect(result).to eq('/repo/app/models/user.rb')
    end

    it 'keeps workspace-prefixed paths as-is' do
      ENV['GITHUB_WORKSPACE'] = '/repo'

      result = collate.send(:normalize_path, '/repo/app/models/user.rb')
      expect(result).to eq('/repo/app/models/user.rb')
    end

    it 'converts absolute paths to workspace-expanded path when needed' do
      ENV['GITHUB_WORKSPACE'] = '/repo'

      result = collate.send(:normalize_path, '/other/path/user.rb')
      expect(result).to eq('/repo/other/path/user.rb')
    end

    it 'returns relative path from workspace' do
      ENV['GITHUB_WORKSPACE'] = '/repo'
      expect(collate.send(:relative_path, '/repo/app/models/user.rb')).to eq('app/models/user.rb')
    end

    it 'calculates file coverage stats including uncovered lines' do
      stats = collate.send(:file_coverage, [1, 0, nil, 2, 0])

      expect(stats).to eq({ covered: 2, total: 4, uncovered: [2, 5], percentage: 50.0 })
    end

    it 'returns zeroed file coverage for non-executable files' do
      expect(collate.send(:file_coverage, [nil, nil])).to eq({ covered: 0, total: 0, percentage: 0.0, uncovered: [] })
    end

    it 'builds a coverage result from merged coverage' do
      ENV['GITHUB_WORKSPACE'] = '/repo'
      ENV['SIMPLECOV_GROUPS'] = "Models:app/models\nServices:app/services"

      merged = {
        '/repo/app/models/user.rb' => [1, 0, nil],
        '/repo/app/services/auth.rb' => [1, 1, nil]
      }

      result = collate.send(:build_coverage_result, merged)

      expect(result[:total_lines]).to eq(4)
      expect(result[:covered_lines]).to eq(3)
      expect(result[:total_coverage]).to eq(75.0)
      expect(result[:files].map { |f| f[:path] }).to eq(%w[app/models/user.rb app/services/auth.rb])
      expect(result[:groups].map { |g| g[:name] }).to eq(%w[Models Services])
    end

    it 'filters out groups with zero executable lines' do
      ENV['GITHUB_WORKSPACE'] = '/repo'
      ENV['SIMPLECOV_GROUPS'] = "Dead:app/dead\nLive:app/live"
      merged = {
        '/repo/app/live/code.rb' => [1, nil]
      }

      groups = collate.send(:calculate_group_coverages, merged)
      expect(groups.map { |g| g[:name] }).to eq(['Live'])
    end

    it 'writes merged resultset json and coverage result json' do
      Dir.mktmpdir do |dir|
        ENV['COVERAGE_PATH'] = dir
        path = collate.send(:write_merged_resultset, { 'file.rb' => [1, 0] })
        expect(File).to exist(path)

        collate.send(:write_coverage_result, { total_coverage: 50.0 })
        expect(File).to exist(File.join(dir, 'coverage_result.json'))
      end
    end

    it 'aborts when resultset file is unreadable or invalid' do
      Dir.mktmpdir do |dir|
        file = File.join(dir, 'bad.json')
        File.write(file, '{not-json')

        expect { collate.send(:merge_single_resultset!, {}, file) }.to raise_error(SystemExit)
      end
    end

    it 'validates and aborts when no coverage data exists' do
      allow(collate).to receive(:merge_single_resultset!).and_return(0)

      expect { collate.send(:validate_and_merge, ['a.json']) }.to raise_error(SystemExit)
    end

    it 'validates and returns merged coverage when coverage exists' do
      allow(collate).to receive(:merge_single_resultset!) do |merged, file|
        merged[file] = [1]
        1
      end

      merged = collate.send(:validate_and_merge, %w[first.json second.json])
      expect(merged.keys).to contain_exactly('first.json', 'second.json')
    end

    it 'merges resultset coverage for hash and array file data and existing files' do
      ENV['GITHUB_WORKSPACE'] = '/repo'
      merged = {}

      collate.send(:merge_resultset_coverage!, merged, {
                     '/github/workspace/app/models/user.rb' => { 'lines' => [1, nil, 0] }
                   })

      collate.send(:merge_resultset_coverage!, merged, {
                     '/github/workspace/app/models/user.rb' => [2, 1, nil]
                   })

      expect(merged['/repo/app/models/user.rb']).to eq([3, 1, 0])
    end

    it 'calculates file coverages including only executable files in output list' do
      ENV['GITHUB_WORKSPACE'] = '/repo'
      merged = {
        '/repo/app/a.rb' => [nil, nil],
        '/repo/app/b.rb' => [1, 0, nil]
      }

      files, total, covered = collate.send(:calculate_file_coverages, merged)
      expect(total).to eq(2)
      expect(covered).to eq(1)
      expect(files.map { |f| f[:path] }).to eq(['app/b.rb'])
    end

    it 'generates html report with configured filters and groups' do
      ENV['COVERAGE_PATH'] = 'coverage'
      ENV['SIMPLECOV_PROFILE'] = 'rails'
      ENV['SIMPLECOV_FILTERS'] = '^spec/'
      ENV['SIMPLECOV_GROUPS'] = 'Models:app/models'

      fake_config = double('simplecov_config')
      allow(fake_config).to receive(:filters).and_return(['^spec/'])
      allow(fake_config).to receive(:groups).and_return(['Models:app/models'])
      allow(fake_config).to receive(:add_filter)
      allow(fake_config).to receive(:add_group)

      stub_simplecov_collate_with(fake_config)

      collate.send(:generate_html_report, 'coverage/.resultset.json')

      expect(SimpleCov).to have_received(:coverage_dir).with('coverage')
      expect(SimpleCov).to have_received(:formatters=).with([SimpleCov::Formatter::HTMLFormatter])
      expect(fake_config).to have_received(:add_filter).with(Regexp.new('^spec/'))
      expect(fake_config).to have_received(:add_group).with('Models', 'app/models')
    end

    it 'skips invalid group entries while generating html report' do
      ENV['COVERAGE_PATH'] = 'coverage'
      ENV['SIMPLECOV_PROFILE'] = 'rails'
      ENV['SIMPLECOV_GROUPS'] = "Valid:app/models\nInvalidOnlyName"

      fake_config = double('simplecov_config', filters: [], groups: ['Valid:app/models', 'InvalidOnlyName'])
      allow(fake_config).to receive(:add_filter)
      allow(fake_config).to receive(:add_group)

      stub_simplecov_collate_with(fake_config)

      collate.send(:generate_html_report, 'coverage/.resultset.json')

      expect(fake_config).to have_received(:add_group).with('Valid', 'app/models')
      expect(fake_config).not_to have_received(:add_group).with('InvalidOnlyName', anything)
    end

    it 'runs full orchestration' do
      allow(FileUtils).to receive(:mkdir_p)
      allow(collate).to receive(:find_resultset_files).and_return(['a.json'])
      allow(collate).to receive(:validate_and_merge).and_return({ 'file.rb' => [1] })
      allow(collate).to receive(:write_merged_resultset).and_return('coverage/.resultset.json')
      allow(collate).to receive(:log_merged_structure)
      allow(collate).to receive(:generate_html_report)
      allow(collate).to receive(:build_coverage_result).and_return({ total_coverage: 100.0, total_lines: 1, covered_lines: 1,
                                                                     groups: [] })
      allow(collate).to receive(:write_coverage_result)
      allow(collate).to receive(:print_summary)

      collate.run

      expect(collate).to have_received(:find_resultset_files)
      expect(collate).to have_received(:validate_and_merge).with(['a.json'])
      expect(collate).to have_received(:generate_html_report).with('coverage/.resultset.json')
      expect(collate).to have_received(:write_coverage_result)
    end
  end
end

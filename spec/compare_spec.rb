# frozen_string_literal: true

require 'spec_helper'
require_relative '../scripts/compare'

RSpec.describe SimpleCovDelta::Compare do
  subject(:compare) { described_class.new }

  around do |example|
    original = ENV.to_h
    begin
      example.run
    ensure
      ENV.replace(original)
    end
  end

  let(:merged_resultset) { fixture_path('merged_resultset.json') }
  let(:baseline_resultset) { fixture_path('baseline_resultset.json') }

  describe '#normalize_path' do
    it 'strips /home/runner/work/<repo>/<repo>/ prefix' do
      result = compare.normalize_path('/home/runner/work/myapp/myapp/app/models/user.rb')
      expect(result).to eq('app/models/user.rb')
    end

    it 'strips /github/workspace/ prefix' do
      result = compare.normalize_path('/github/workspace/app/models/user.rb')
      expect(result).to eq('app/models/user.rb')
    end

    it 'handles paths without known prefixes' do
      result = compare.normalize_path('/some/other/path/app/models/user.rb')
      expect(result).to eq('some/other/path/app/models/user.rb')
    end
  end

  describe '#parse_resultset' do
    it 'parses a .resultset.json file into normalized file coverage' do
      files = compare.parse_resultset(merged_resultset)

      expect(files).to have_key('app/models/user.rb')
      expect(files).to have_key('app/services/auth_service.rb')
      expect(files).to have_key('app/models/account.rb')
      expect(files).to have_key('app/graphql/types/user_type.rb')
    end

    it 'returns correct line arrays' do
      files = compare.parse_resultset(merged_resultset)
      expect(files['app/models/user.rb'][:lines]).to eq([1, 1, nil, 1, 1, nil, 1, 1, 1, nil])
    end
  end

  describe '#file_coverage' do
    it 'computes coverage stats correctly' do
      # 7 executable lines (non-nil), 6 covered (>0), 1 uncovered (0)
      lines = [1, 1, nil, 1, 1, nil, 1, 1, 0, nil]
      stats = compare.file_coverage(lines)

      expect(stats[:total]).to eq(7)
      expect(stats[:covered]).to eq(6)
      expect(stats[:percentage]).to eq(85.71)
    end

    it 'handles empty lines' do
      stats = compare.file_coverage([nil, nil, nil])
      expect(stats[:total]).to eq(0)
      expect(stats[:percentage]).to eq(0.0)
    end

    it 'handles all covered' do
      stats = compare.file_coverage([1, 2, 3])
      expect(stats[:total]).to eq(3)
      expect(stats[:covered]).to eq(3)
      expect(stats[:percentage]).to eq(100.0)
    end
  end

  describe '#uncovered_lines' do
    it 'returns 1-based line numbers of uncovered lines' do
      lines = [1, 0, nil, 0, 1, nil, 0]
      result = compare.uncovered_lines(lines)
      expect(result).to eq([2, 4, 7])
    end

    it 'returns empty array when all lines are covered' do
      lines = [1, 2, nil, 3]
      result = compare.uncovered_lines(lines)
      expect(result).to eq([])
    end
  end

  describe '#group_coverage' do
    let(:files) do
      {
        'app/models/user.rb' => { lines: [1, 1, nil, 0] },
        'app/models/account.rb' => { lines: [1, 1, 1, nil] },
        'app/services/auth_service.rb' => { lines: [1, 0, 0, nil] }
      }
    end

    let(:groups) do
      [
        { name: 'Models', path: 'app/models' },
        { name: 'Services', path: 'app/services' }
      ]
    end

    it 'computes per-group coverage' do
      result = compare.group_coverage(files, groups)

      models = result.find { |g| g[:name] == 'Models' }
      expect(models[:total]).to eq(6)
      expect(models[:covered]).to eq(5)
      expect(models[:coverage]).to eq(83.33)

      services = result.find { |g| g[:name] == 'Services' }
      expect(services[:total]).to eq(3)
      expect(services[:covered]).to eq(1)
      expect(services[:coverage]).to eq(33.33)
    end
  end

  describe 'private behavior' do
    it 'returns defaults for environment-backed settings' do
      expect(compare.coverage_path).to eq('coverage')
      expect(compare.baseline_path).to eq('')
      expect(compare.api_url).to eq('https://api.github.com')
    end

    it 'aborts when current resultset is missing' do
      ENV['COVERAGE_PATH'] = '/tmp/missing-coverage-path'
      ENV['BASELINE_PATH'] = '/tmp/baseline.json'

      expect { compare.run }.to raise_error(SystemExit)
    end

    it 'skips comparison when baseline file is missing' do
      Dir.mktmpdir do |dir|
        ENV['COVERAGE_PATH'] = dir
        File.write(File.join(dir, '.resultset.json'), '{}')
        ENV['BASELINE_PATH'] = File.join(dir, 'missing_baseline.json')

        expect { compare.run }.not_to raise_error
      end
    end

    it 'runs full comparison flow when both files exist' do
      Dir.mktmpdir do |dir|
        current = File.join(dir, '.resultset.json')
        baseline = File.join(dir, 'baseline.json')
        File.write(current, '{}')
        File.write(baseline, '{}')

        ENV['COVERAGE_PATH'] = dir
        ENV['BASELINE_PATH'] = baseline

        allow(compare).to receive(:parse_resultset).and_return({})
        allow(compare).to receive(:build_comparison).and_return({ overall: { current: 0.0, baseline: 0.0, delta: 0.0 },
                                                                  changed_files: [], all_changed_coverage_files: [] })
        allow(compare).to receive(:write_comparison)
        allow(compare).to receive(:print_summary)

        compare.run

        expect(compare).to have_received(:parse_resultset).with(current)
        expect(compare).to have_received(:parse_resultset).with(baseline)
        expect(compare).to have_received(:write_comparison)
      end
    end

    it 'merges line arrays for same file across commands in parse_resultset' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, '.resultset.json')
        payload = {
          'cmd1' => { 'coverage' => { '/github/workspace/a.rb' => { 'lines' => [1, 0, nil] } } },
          'cmd2' => { 'coverage' => { '/github/workspace/a.rb' => { 'lines' => [2, 1, 3] } } }
        }
        File.write(path, JSON.generate(payload))

        files = compare.parse_resultset(path)
        expect(files['a.rb'][:lines]).to eq([3, 1, 3])
      end
    end

    it 'builds changed file results with and without baseline data' do
      current_files = { 'a.rb' => { lines: [1, 0] }, 'b.rb' => { lines: [1, 1] } }
      baseline_files = { 'a.rb' => { lines: [1, 1] } }

      result = compare.send(:compare_changed_files, current_files, baseline_files, %w[a.rb b.rb c.rb])

      expect(result.size).to eq(2)
      a = result.find { |r| r[:path] == 'a.rb' }
      b = result.find { |r| r[:path] == 'b.rb' }
      expect(a[:baseline]).to eq(100.0)
      expect(a[:delta]).to eq(-50.0)
      expect(b[:baseline]).to be_nil
      expect(b[:delta]).to be_nil
    end

    it 'finds non-pr changed coverage files and sorts by delta magnitude' do
      current = {
        'a.rb' => { lines: [1, 0] },
        'b.rb' => { lines: [1, 1] }
      }
      baseline = {
        'a.rb' => { lines: [1, 1] },
        'c.rb' => { lines: [1, 0] }
      }

      result = compare.send(:find_all_changed_coverage, current, baseline, ['b.rb'])
      expect(result.map { |r| r[:path] }).to include('a.rb', 'c.rb')
      expect(result.first).to have_key(:delta)
    end

    it 'calculates overall coverage and deltas' do
      files = {
        'a.rb' => { lines: [1, 0, nil] },
        'b.rb' => { lines: [1, 1, nil] }
      }

      overall = compare.send(:calculate_overall, files)
      expect(overall).to eq(75.0)

      delta = compare.send(:calculate_overall_delta, files, {})
      expect(delta[:current]).to eq(75.0)
      expect(delta[:baseline]).to eq(0.0)
      expect(delta[:delta]).to eq(75.0)
    end

    it 'parses group definitions and calculates group deltas' do
      ENV['SIMPLECOV_GROUPS'] = "Models:app/models\nServices:app/services"
      current = {
        'app/models/user.rb' => { lines: [1, 0] },
        'app/services/a.rb' => { lines: [1, 1] }
      }
      baseline = {
        'app/models/user.rb' => { lines: [1, 1] },
        'app/services/a.rb' => { lines: [1, 0] }
      }

      groups = compare.send(:calculate_group_deltas, current, baseline)
      expect(groups.map { |g| g[:name] }).to eq(%w[Models Services])
      expect(groups.all? { |g| g.key?(:delta) }).to be true
    end

    it 'merges file lines into existing file coverage' do
      files = { 'a.rb' => { lines: [1, nil, 1] } }

      compare.send(:merge_file_lines!, files, 'a.rb', [2, 1, nil])
      compare.send(:merge_file_lines!, files, 'b.rb', [0, nil])

      expect(files['a.rb'][:lines]).to eq([3, 1, 1])
      expect(files['b.rb'][:lines]).to eq([0, nil])
    end

    it 'fetches changed files from github pull request api' do
      Dir.mktmpdir do |dir|
        event = File.join(dir, 'event.json')
        File.write(event, JSON.generate({ 'pull_request' => { 'number' => 12 } }))

        ENV['GITHUB_EVENT_PATH'] = event
        ENV['GITHUB_REPOSITORY'] = 'org/repo'
        ENV['GITHUB_TOKEN'] = 'token'

        file1 = double('pr_file_1', filename: 'a.rb')
        file2 = double('pr_file_2', filename: 'b.rb')
        client = instance_double(Octokit::Client, pull_request_files: [file1, file2])

        allow(Octokit::Client).to receive(:new).and_return(client)

        expect(compare.send(:fetch_changed_files)).to eq(%w[a.rb b.rb])
      end
    end

    it 'returns empty list when event file is missing or has no pr number' do
      expect(compare.send(:fetch_changed_files)).to eq([])

      Dir.mktmpdir do |dir|
        event = File.join(dir, 'event.json')
        File.write(event, JSON.generate({}))
        ENV['GITHUB_EVENT_PATH'] = event

        expect(compare.send(:fetch_changed_files)).to eq([])
      end
    end

    it 'rescues octokit errors while fetching changed files' do
      Dir.mktmpdir do |dir|
        event = File.join(dir, 'event.json')
        File.write(event, JSON.generate({ 'pull_request' => { 'number' => 12 } }))

        ENV['GITHUB_EVENT_PATH'] = event
        ENV['GITHUB_REPOSITORY'] = 'org/repo'

        client = instance_double(Octokit::Client)
        allow(client).to receive(:pull_request_files).and_raise(Octokit::NotFound)
        allow(Octokit::Client).to receive(:new).and_return(client)

        expect(compare.send(:fetch_changed_files)).to eq([])
      end
    end

    it 'writes comparison json and prints summary with sign' do
      Dir.mktmpdir do |dir|
        ENV['COVERAGE_PATH'] = dir
        comparison = {
          overall: { current: 80.0, baseline: 70.0, delta: 10.0 },
          changed_files: [{ path: 'a.rb' }],
          all_changed_coverage_files: []
        }

        compare.send(:write_comparison, comparison)
        expect(File).to exist(File.join(dir, 'comparison.json'))
        expect { compare.send(:print_summary, comparison) }.not_to raise_error
      end
    end

    it 'builds complete comparison structure' do
      current = { 'a.rb' => { lines: [1, 0] } }
      baseline = { 'a.rb' => { lines: [1, 1] } }
      allow(compare).to receive(:fetch_changed_files).and_return(['a.rb'])

      result = compare.send(:build_comparison, current, baseline)

      expect(result).to have_key(:overall)
      expect(result).to have_key(:groups)
      expect(result).to have_key(:changed_files)
      expect(result).to have_key(:all_changed_coverage_files)
    end

    it 'calculates group deltas when baseline group not found' do
      # Simulate scenario where baseline has different groups
      current_groups = [
        { name: 'Libraries', coverage: 95.0, total: 100, covered: 95 },
        { name: 'Models', coverage: 80.0, total: 50, covered: 40 }
      ]
      baseline_groups = [
        { name: 'Models', coverage: 75.0, total: 40, covered: 30 }
        # Libraries group doesn't exist in baseline
      ]

      allow(compare).to receive(:group_coverage).and_return(current_groups, baseline_groups)

      result = compare.send(:calculate_group_deltas, {}, {})

      libraries_group = result.find { |g| g[:name] == 'Libraries' }
      expect(libraries_group[:baseline]).to be_nil
      expect(libraries_group[:delta]).to be_nil
    end

    it 'parses resultset when file_data is hash with nil lines' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, '.resultset.json')
        payload = {
          'cmd1' => {
            'coverage' => {
              '/github/workspace/a.rb' => { 'lines' => nil }
            }
          }
        }
        File.write(path, JSON.generate(payload))

        files = compare.parse_resultset(path)
        expect(files['a.rb'][:lines]).to eq([])
      end
    end

    it 'prints summary with negative delta' do
      comparison = {
        overall: { current: 70.0, baseline: 80.0, delta: -10.0 },
        changed_files: [],
        all_changed_coverage_files: []
      }

      expect { compare.send(:print_summary, comparison) }.to output(/Delta: -10.0%/).to_stdout
    end

    it 'filters out files with zero delta from all_changed_coverage' do
      current = {
        'changed.rb' => { lines: [1, 1] },
        'same.rb' => { lines: [1, 1] },
        'different.rb' => { lines: [1, 0] }
      }
      baseline = {
        'changed.rb' => { lines: [1, 1] },
        'same.rb' => { lines: [1, 1] },
        'different.rb' => { lines: [1, 1] }
      }

      result = compare.send(:find_all_changed_coverage, current, baseline, ['changed.rb'])

      # same.rb should be filtered out because delta is zero
      expect(result.map { |f| f[:path] }).to eq(['different.rb'])
    end

    it 'calculates file delta when current_data is nil' do
      result = compare.send(:calculate_file_delta, nil, { lines: [1, 1] })

      expect(result[:current]).to eq(0.0)
      expect(result[:baseline]).to eq(100.0)
      expect(result[:delta]).to eq(-100.0)
    end

    it 'calculates file delta when baseline_data is nil' do
      result = compare.send(:calculate_file_delta, { lines: [1, 1] }, nil)

      expect(result[:current]).to eq(100.0)
      expect(result[:baseline]).to eq(0.0)
      expect(result[:delta]).to eq(100.0)
    end

    it 'returns empty array when event has no pr number' do
      Dir.mktmpdir do |dir|
        event_file = File.join(dir, 'event.json')
        File.write(event_file, JSON.generate({ some_other_event: true }))
        ENV['GITHUB_EVENT_PATH'] = event_file

        expect(compare.send(:fetch_changed_files)).to eq([])
      end
    end
  end
end

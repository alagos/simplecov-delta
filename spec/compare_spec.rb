# frozen_string_literal: true

require 'spec_helper'

require_relative '../scripts/compare'

RSpec.describe SimpleCovDelta::Compare do
  subject(:compare) { described_class.new }

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
end

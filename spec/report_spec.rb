# frozen_string_literal: true

require 'spec_helper'

require_relative '../scripts/report'

RSpec.describe SimpleCovDelta::Report do
  describe '.delta_indicator' do
    it 'returns dash for nil' do
      expect(described_class.delta_indicator(nil)).to eq('—')
    end

    it 'formats positive delta with check mark' do
      expect(described_class.delta_indicator(1.3)).to eq('+1.3% ✅')
    end

    it 'formats negative delta with warning' do
      expect(described_class.delta_indicator(-2.5)).to eq('-2.5% ⚠️')
    end

    it 'formats zero delta' do
      expect(described_class.delta_indicator(0.0)).to eq('+0.0%')
    end
  end

  describe '.format_uncovered_lines' do
    it 'returns dash for empty lines' do
      expect(described_class.format_uncovered_lines([])).to eq('—')
      expect(described_class.format_uncovered_lines(nil)).to eq('—')
    end

    it 'formats single lines' do
      expect(described_class.format_uncovered_lines([5, 10, 15])).to eq('5, 10, 15')
    end

    it 'groups consecutive lines into ranges' do
      expect(described_class.format_uncovered_lines([5, 6, 7, 10, 15, 16])).to eq('5-7, 10, 15-16')
    end

    it 'handles single-element arrays' do
      expect(described_class.format_uncovered_lines([42])).to eq('42')
    end
  end

  describe '.build_annotations' do
    it 'returns empty array when no comparison' do
      expect(described_class.build_annotations(nil)).to eq([])
    end

    it 'builds annotations from uncovered lines' do
      comparison = {
        'changed_files' => [
          {
            'path' => 'app/models/user.rb',
            'uncovered_lines' => [5, 6, 7, 12]
          }
        ]
      }

      annotations = described_class.build_annotations(comparison)
      expect(annotations.size).to eq(2)

      expect(annotations[0][:path]).to eq('app/models/user.rb')
      expect(annotations[0][:start_line]).to eq(5)
      expect(annotations[0][:end_line]).to eq(7)
      expect(annotations[0][:message]).to eq('Lines 5-7 are not covered by tests')

      expect(annotations[1][:start_line]).to eq(12)
      expect(annotations[1][:end_line]).to eq(12)
      expect(annotations[1][:message]).to eq('Line 12 is not covered by tests')
    end

    it 'skips files with no uncovered lines' do
      comparison = {
        'changed_files' => [
          { 'path' => 'app/models/user.rb', 'uncovered_lines' => [] }
        ]
      }

      expect(described_class.build_annotations(comparison)).to eq([])
    end
  end

  describe '.build_groups_table' do
    it 'returns empty string when no groups' do
      expect(described_class.build_groups_table([])).to eq('')
      expect(described_class.build_groups_table(nil)).to eq('')
    end

    it 'builds table with deltas when baseline is present' do
      groups = [
        { 'name' => 'Models', 'current' => 78.1, 'baseline' => 77.8, 'delta' => 0.3 },
        { 'name' => 'Services', 'current' => 49.2, 'baseline' => 50.3, 'delta' => -1.1 }
      ]

      table = described_class.build_groups_table(groups)
      expect(table).to include('Models')
      expect(table).to include('78.1%')
      expect(table).to include('+0.3%')
      expect(table).to include('Services')
      expect(table).to include('-1.1%')
    end

    it 'builds table without deltas when no baseline' do
      groups = [
        { 'name' => 'Models', 'current' => 78.1 },
        { 'name' => 'Services', 'current' => 49.2 }
      ]

      table = described_class.build_groups_table(groups)
      expect(table).to include('Models')
      expect(table).not_to include('Δ')
    end
  end

  describe '.build_pr_comment' do
    let(:coverage_result) do
      {
        'total_coverage' => 54.2,
        'groups' => [
          { 'name' => 'Models', 'coverage' => 78.1 }
        ]
      }
    end

    it 'builds comment without comparison' do
      comment = described_class.build_pr_comment(coverage_result, nil, 'https://example.com/run/1')
      expect(comment).to include('<!-- simplecov-delta -->')
      expect(comment).to include('54.2%')
      expect(comment).to include('Coverage Report')
    end

    it 'builds comment with comparison' do
      comparison = {
        'overall' => { 'current' => 54.2, 'baseline' => 52.9, 'delta' => 1.3 },
        'groups' => [
          { 'name' => 'Models', 'current' => 78.1, 'baseline' => 77.8, 'delta' => 0.3 }
        ],
        'changed_files' => [
          { 'path' => 'app/models/user.rb', 'current' => 89.2, 'baseline' => 86.1, 'delta' => 3.1,
            'uncovered_lines' => [] }
        ]
      }

      comment = described_class.build_pr_comment(coverage_result, comparison, 'https://example.com/run/1')
      expect(comment).to include('+1.3%')
      expect(comment).to include('Models')
      expect(comment).to include('user.rb')
    end
  end

  describe '.build_job_summary' do
    let(:coverage_result) do
      { 'total_coverage' => 54.2, 'groups' => [] }
    end

    it 'builds full details markdown' do
      comparison = {
        'overall' => { 'current' => 54.2, 'baseline' => 52.9, 'delta' => 1.3 },
        'groups' => [],
        'changed_files' => [],
        'all_changed_coverage_files' => [
          { 'path' => 'app/helpers/helper.rb', 'current' => 45.0, 'baseline' => 48.0, 'delta' => -3.0 }
        ]
      }

      summary = described_class.build_job_summary(coverage_result, comparison, 'https://example.com/run/1')
      expect(summary).to include('Full Details')
      expect(summary).to include('helper.rb')
      expect(summary).to include('All Files with Coverage Changes')
    end

    it 'builds summary without comparison' do
      summary = described_class.build_job_summary(coverage_result, nil, 'https://example.com/run/1')
      expect(summary).to include('54.2%')
      expect(summary).not_to include('baseline')
    end
  end
end

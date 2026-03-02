# frozen_string_literal: true

require 'spec_helper'
require_relative '../scripts/report'

RSpec.describe SimpleCovDelta::Report do
  subject(:report) { described_class.new }

  around do |example|
    original = ENV.to_h
    begin
      example.run
    ensure
      ENV.replace(original)
    end
  end

  describe '#delta_indicator' do
    it 'returns dash for nil' do
      expect(report.delta_indicator(nil)).to eq('—')
    end

    it 'formats positive delta with check mark' do
      expect(report.delta_indicator(1.3)).to eq('+1.3% ✅')
    end

    it 'formats negative delta with warning' do
      expect(report.delta_indicator(-2.5)).to eq('-2.5% ⚠️')
    end

    it 'formats zero delta' do
      expect(report.delta_indicator(0.0)).to eq('+0.0%')
    end
  end

  describe '#format_uncovered_lines' do
    it 'returns dash for empty lines' do
      expect(report.format_uncovered_lines([])).to eq('—')
      expect(report.format_uncovered_lines(nil)).to eq('—')
    end

    it 'formats single lines' do
      expect(report.format_uncovered_lines([5, 10, 15])).to eq('5, 10, 15')
    end

    it 'groups consecutive lines into ranges' do
      expect(report.format_uncovered_lines([5, 6, 7, 10, 15, 16])).to eq('5-7, 10, 15-16')
    end

    it 'handles single-element arrays' do
      expect(report.format_uncovered_lines([42])).to eq('42')
    end
  end

  describe '#build_annotations' do
    it 'returns empty array when no comparison' do
      expect(report.build_annotations(nil)).to eq([])
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

      annotations = report.build_annotations(comparison)
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

      expect(report.build_annotations(comparison)).to eq([])
    end
  end

  describe '#build_groups_table' do
    it 'returns empty string when no groups' do
      expect(report.build_groups_table([])).to eq('')
      expect(report.build_groups_table(nil)).to eq('')
    end

    it 'builds table with deltas when baseline is present' do
      groups = [
        { 'name' => 'Models', 'current' => 78.1, 'baseline' => 77.8, 'delta' => 0.3 },
        { 'name' => 'Services', 'current' => 49.2, 'baseline' => 50.3, 'delta' => -1.1 }
      ]

      table = report.build_groups_table(groups)
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

      table = report.build_groups_table(groups)
      expect(table).to include('Models')
      expect(table).not_to include('Δ')
    end
  end

  describe '#build_pr_comment' do
    let(:coverage_result) do
      {
        'total_coverage' => 54.2,
        'groups' => [
          { 'name' => 'Models', 'coverage' => 78.1 }
        ]
      }
    end

    it 'builds comment without comparison' do
      comment = report.build_pr_comment(coverage_result, nil)
      expect(comment).to include('<!-- coverage-report-action -->')
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

      comment = report.build_pr_comment(coverage_result, comparison)
      expect(comment).to include('+1.3%')
      expect(comment).to include('Models')
      expect(comment).to include('user.rb')
    end
  end

  describe '#build_job_summary' do
    let(:coverage_result) do
      {
        'total_coverage' => 54.2,
        'groups' => [],
        'files' => [
          {
            'path' => 'webapp/app/models/user.rb',
            'coverage' => 89.2,
            'total_lines' => 112,
            'covered_lines' => 100,
            'uncovered_lines' => [12, 34, 35]
          }
        ]
      }
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

      summary = report.build_job_summary(coverage_result, comparison)
      expect(summary).to include('Full Details')
      expect(summary).to include('helper.rb')
      expect(summary).to include('All Files with Coverage Changes')
    end

    it 'builds summary without comparison' do
      summary = report.build_job_summary(coverage_result, nil)
      expect(summary).to include('54.2%')
      expect(summary).not_to include('baseline')
      expect(summary).to include('All Covered Files')
      expect(summary).to include('user.rb')
    end
  end

  describe 'private behavior' do
    it 'builds no-comparison sections with and without all files' do
      coverage_result = {
        'groups' => [{ 'name' => 'Models', 'coverage' => 50.0 }],
        'files' => [{ 'path' => 'a.rb', 'coverage' => 100.0, 'covered_lines' => 1, 'total_lines' => 1,
                      'uncovered_lines' => [] }]
      }

      text = report.send(:no_comparison_sections, coverage_result, include_all_files: true)
      expect(text).to include('By Group')
      expect(text).to include('All Covered Files')

      short_text = report.send(:no_comparison_sections, coverage_result, include_all_files: false)
      expect(short_text).to include('By Group')
      expect(short_text).not_to include('All Covered Files')
    end

    it 'builds changed files table in both baseline and no-baseline modes' do
      with_baseline = report.send(:build_changed_files_table, [{ 'path' => 'a.rb', 'current' => 50.0, 'baseline' => 40.0,
                                                                 'delta' => 10.0, 'uncovered_lines' => [2] }])
      no_baseline = report.send(:build_changed_files_table,
                                [{ 'path' => 'b.rb', 'current' => 50.0, 'uncovered_lines' => [3] }])

      expect(with_baseline).to include('Δ')
      expect(no_baseline).not_to include('| Δ |')
    end

    it 'builds all-changed and all-files tables' do
      all_changed = report.send(:build_all_changed_table, [{ 'path' => 'a.rb', 'current' => 40.0, 'delta' => -1.0 }])
      all_files = report.send(:build_all_files_table, [{ 'path' => 'a.rb', 'coverage' => 40.0, 'covered_lines' => 2,
                                                         'total_lines' => 5, 'uncovered_lines' => [3, 4] }])

      expect(all_changed).to include('a.rb')
      expect(all_files).to include('2 / 5')
      expect(all_files).to include('3-4')
      expect(report.send(:build_all_changed_table, nil)).to eq('')
      expect(report.send(:build_all_files_table, [])).to eq('')
    end

    it 'groups consecutive lines and creates annotation ranges' do
      grouped = report.send(:group_consecutive, [1, 2, 3, 8, 10, 11])
      expect(grouped).to eq([[1, 2, 3], [8], [10, 11]])

      annotations = report.send(:ranges_to_annotations, 'a.rb', [2, 3, 6])
      expect(annotations.size).to eq(2)
      expect(annotations.first[:message]).to include('2-3')
      expect(annotations.last[:message]).to include('Line 6')
    end

    it 'builds single and range annotation messages' do
      single = report.send(:build_annotation, 'a.rb', { start: 4, end: 4 })
      range = report.send(:build_annotation, 'a.rb', { start: 4, end: 9 })

      expect(single[:message]).to eq('Line 4 is not covered by tests')
      expect(range[:message]).to eq('Lines 4-9 are not covered by tests')
    end

    it 'determines neutral conclusion on threshold or negative delta' do
      ENV['MIN_COVERAGE'] = '75'
      low = report.send(:determine_conclusion, { 'total_coverage' => 70.0 }, nil)
      expect(low).to eq('neutral')

      ok_but_negative = report.send(:determine_conclusion, { 'total_coverage' => 80.0 },
                                    { 'overall' => { 'delta' => -0.1 } })
      expect(ok_but_negative).to eq('neutral')

      success = report.send(:determine_conclusion, { 'total_coverage' => 80.0 }, { 'overall' => { 'delta' => 0.1 } })
      expect(success).to eq('success')
    end

    it 'builds check run summary with and without comparison' do
      summary_with = report.send(:check_run_summary, { 'total_coverage' => 80.12 },
                                 { 'overall' => { 'delta' => 1.25 } })
      summary_without = report.send(:check_run_summary, { 'total_coverage' => 80.12 }, nil)

      expect(summary_with).to include('(+1.2% vs baseline)')
      expect(summary_without).to eq('Coverage: 80.1%')
    end

    it 'filters annotations based on ANNOTATIONS env' do
      annotations = [{ path: 'a.rb' }]
      ENV['ANNOTATIONS'] = 'false'
      expect(report.send(:filter_annotations, annotations)).to eq([])

      report.instance_variable_set(:@annotations_enabled, nil)
      ENV['ANNOTATIONS'] = 'true'
      expect(report.send(:filter_annotations, annotations)).to eq(annotations)
    end

    it 'submits check run and remaining annotation batches' do
      client = instance_double(Octokit::Client)
      check_run = double('check_run', id: 123)
      allow(report).to receive(:github_client).and_return(client)
      allow(client).to receive(:create_check_run).and_return(check_run)
      allow(client).to receive(:update_check_run)
      ENV['GITHUB_REPOSITORY'] = 'org/repo'
      ENV['GITHUB_SHA'] = 'abc123'

      annotations = (1..55).map do |i|
        { path: 'a.rb', start_line: i, end_line: i, annotation_level: 'warning', message: "m#{i}" }
      end

      id = report.send(:submit_check_run, 'Coverage Report', 'abc123', 'success', 'Summary', annotations)
      report.send(:submit_remaining_annotations, id, 'Summary', annotations)

      expect(id).to eq(123)
      expect(client).to have_received(:create_check_run)
      expect(client).to have_received(:update_check_run).at_least(:once)
    end

    it 'creates check run and rescues octokit errors' do
      allow(report).to receive(:determine_conclusion).and_return('success')
      allow(report).to receive(:check_run_summary).and_return('Summary')
      allow(report).to receive(:filter_annotations).and_return([])
      allow(report).to receive(:submit_check_run).and_return(1)
      allow(report).to receive(:submit_remaining_annotations)

      report.send(:create_check_run, [], { 'total_coverage' => 100.0 }, nil)
      expect(report).to have_received(:submit_check_run)

      allow(report).to receive(:submit_check_run).and_raise(Octokit::NotFound)
      expect { report.send(:create_check_run, [], { 'total_coverage' => 100.0 }, nil) }.not_to raise_error
    end

    it 'writes job summary when summary path exists, otherwise skips' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'summary.md')
        ENV['GITHUB_STEP_SUMMARY'] = path

        report.send(:write_job_summary, 'hello')
        expect(File.read(path)).to include('hello')

        report.instance_variable_set(:@step_summary_path, nil)
        ENV['GITHUB_STEP_SUMMARY'] = ''
        expect { report.send(:write_job_summary, 'world') }.not_to raise_error
      end
    end

    it 'extracts current pr number from event payload' do
      Dir.mktmpdir do |dir|
        event = File.join(dir, 'event.json')
        File.write(event, JSON.generate({ 'pull_request' => { 'number' => 77 } }))
        ENV['GITHUB_EVENT_PATH'] = event

        expect(report.send(:current_pr_number)).to eq(77)
      end
    end

    it 'returns nil pr number when event file is unavailable' do
      expect(report.send(:current_pr_number)).to be_nil
    end

    it 'finds existing sticky coverage comment by marker' do
      comment1 = double('comment_1', body: 'hello')
      comment2 = double('comment_2', body: "x #{SimpleCovDelta::Report::COMMENT_MARKER} y")
      client = instance_double(Octokit::Client, issue_comments: [comment1, comment2])

      allow(report).to receive(:github_client).and_return(client)
      ENV['GITHUB_REPOSITORY'] = 'org/repo'
      found = report.send(:find_existing_comment, 12)

      expect(found).to eq(comment2)
    end

    it 'creates or updates pr comments based on existing marker' do
      ENV['POST_COMMENT'] = 'true'
      ENV['GITHUB_REPOSITORY'] = 'org/repo'

      existing = double('existing_comment', id: 5)
      client = instance_double(Octokit::Client)
      allow(report).to receive(:github_client).and_return(client)
      allow(report).to receive(:current_pr_number).and_return(10)

      allow(report).to receive(:find_existing_comment).and_return(existing)
      allow(client).to receive(:update_comment)
      report.send(:post_or_update_pr_comment, 'body')
      expect(client).to have_received(:update_comment).with('org/repo', 5, 'body')

      allow(report).to receive(:find_existing_comment).and_return(nil)
      allow(client).to receive(:add_comment)
      report.send(:post_or_update_pr_comment, 'body')
      expect(client).to have_received(:add_comment).with('org/repo', 10, 'body')
    end

    it 'skips pr comment posting when disabled or outside pr context' do
      ENV['POST_COMMENT'] = 'false'
      expect { report.send(:post_or_update_pr_comment, 'x') }.not_to raise_error

      report.instance_variable_set(:@post_comment_enabled, nil)
      ENV['POST_COMMENT'] = 'true'
      allow(report).to receive(:current_pr_number).and_return(nil)
      expect { report.send(:post_or_update_pr_comment, 'x') }.not_to raise_error
    end

    it 'returns empty string when changed_files is nil for build_changed_files_table' do
      expect(report.send(:build_changed_files_table, nil)).to eq('')
    end

    it 'builds changed files table without baseline when no files have baseline or delta' do
      # All new files without baseline data
      new_files = [
        { 'path' => 'new_file_1.rb', 'current' => 85.0, 'uncovered_lines' => [5, 6] },
        { 'path' => 'new_file_2.rb', 'current' => 92.3, 'uncovered_lines' => [] }
      ]

      result = report.send(:build_changed_files_table, new_files)
      expect(result).to include('new_file_1.rb')
      expect(result).to include('85.0%')
      expect(result).not_to include('| Δ |')
    end

    it 'returns empty string when groups are empty for build_groups_table' do
      expect(report.send(:build_groups_table, [])).to eq('')
    end

    it 'groups single line correctly in group_consecutive' do
      grouped = report.send(:group_consecutive, [5])
      expect(grouped).to eq([[5]])
    end

    it 'creates empty annotations list from empty uncovered lines' do
      annotations = report.send(:ranges_to_annotations, 'a.rb', [])
      expect(annotations).to eq([])
    end

    it 'returns empty run_url_link when run_url is nil' do
      allow(report).to receive(:run_url).and_return(nil)
      expect(report.send(:run_url_link)).to eq('')

      allow(report).to receive(:run_url).and_return('')
      expect(report.send(:run_url_link)).to eq('')
    end

    it 'determines conclusion based on coverage delta being negative' do
      ENV['MIN_COVERAGE'] = '50'

      # Coverage meets threshold but delta is negative
      neutral = report.send(:determine_conclusion, { 'total_coverage' => 80.0 },
                            { 'overall' => { 'delta' => -5.2 } })
      expect(neutral).to eq('neutral')
    end

    it 'loads coverage and comparison files' do
      Dir.mktmpdir do |dir|
        ENV['COVERAGE_PATH'] = dir
        File.write(File.join(dir, 'coverage_result.json'), JSON.generate({ total_coverage: 1.0 }))
        File.write(File.join(dir, 'comparison.json'), JSON.generate({ overall: { delta: 0.0 } }))

        expect(report.send(:load_coverage_result)).to include('total_coverage' => 1.0)
        expect(report.send(:load_comparison)).to include('overall' => { 'delta' => 0.0 })
      end
    end

    it 'returns nil when comparison json is missing and aborts when coverage json is missing' do
      Dir.mktmpdir do |dir|
        ENV['COVERAGE_PATH'] = dir
        expect(report.send(:load_comparison)).to be_nil
        expect { report.send(:load_coverage_result) }.to raise_error(SystemExit)
      end
    end

    it 'runs full report orchestration' do
      coverage_result = { 'total_coverage' => 50.0, 'groups' => [], 'files' => [] }
      comparison = nil
      allow(report).to receive(:load_coverage_result).and_return(coverage_result)
      allow(report).to receive(:load_comparison).and_return(comparison)
      allow(report).to receive(:build_annotations).and_return([])
      allow(report).to receive(:create_check_run)
      allow(report).to receive(:build_job_summary).and_return('summary')
      allow(report).to receive(:write_job_summary)
      allow(report).to receive(:build_pr_comment).and_return('comment')
      allow(report).to receive(:post_or_update_pr_comment)

      report.run

      expect(report).to have_received(:create_check_run)
      expect(report).to have_received(:write_job_summary).with('summary')
      expect(report).to have_received(:post_or_update_pr_comment).with('comment')
    end
  end
end

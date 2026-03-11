# frozen_string_literal: true

require 'spec_helper'
require_relative '../scripts/report'

RSpec.describe SimpleCovDelta::Report do
  subject(:report) { described_class.new }

  around do |example|
    original = ENV.to_h
    begin
      # Keep URL assertions deterministic regardless of CI-provided GitHub env vars.
      ENV.delete('GITHUB_REPOSITORY')
      ENV.delete('GITHUB_RUN_ID')
      ENV.delete('GITHUB_SERVER_URL')
      example.run
    ensure
      ENV.replace(original)
    end
  end

  describe '#delta_indicator' do
    subject(:result) { report.delta_indicator(delta) }

    context 'when delta is nil' do
      let(:delta) { nil }

      it { is_expected.to eq('—') }
    end

    context 'when delta is positive' do
      let(:delta) { 1.3 }

      it { is_expected.to eq('+1.3% ✅') }
    end

    context 'when delta is negative' do
      let(:delta) { -2.5 }

      it { is_expected.to eq('-2.5% ⚠️') }
    end

    context 'when delta is zero' do
      let(:delta) { 0.0 }

      it { is_expected.to eq('+0.0%') }
    end
  end

  describe '#format_uncovered_lines' do
    subject(:result) { report.format_uncovered_lines(lines) }

    context 'when lines are empty' do
      let(:lines) { [] }

      it { is_expected.to eq('—') }
    end

    context 'when lines are nil' do
      let(:lines) { nil }

      it { is_expected.to eq('—') }
    end

    context 'when lines are single values' do
      let(:lines) { [5, 10, 15] }

      it { is_expected.to eq('5, 10, 15') }
    end

    context 'when lines contain consecutive ranges' do
      let(:lines) { [5, 6, 7, 10, 15, 16] }

      it { is_expected.to eq('5-7, 10, 15-16') }
    end

    context 'when lines has one element' do
      let(:lines) { [42] }

      it { is_expected.to eq('42') }
    end
  end

  describe '#build_annotations' do
    subject(:result) { report.build_annotations(comparison) }

    context 'when comparison is nil' do
      let(:comparison) { nil }

      it { is_expected.to eq([]) }
    end

    context 'when changed files include uncovered lines' do
      let(:comparison) do
        { 'changed_files' => [
          { 'path' => 'app/models/user.rb',
            'uncovered_lines' => [5, 6, 7, 12] }
        ] }
      end

      it 'returns two annotations' do
        expect(result.size).to eq(2)
      end

      it 'builds the first range annotation' do
        expect(result[0]).to eq(
          path: 'app/models/user.rb',
          start_line: 5,
          end_line: 7,
          annotation_level: 'warning',
          message: 'Lines 5-7 are not covered by tests'
        )
      end

      it 'builds the trailing single-line annotation' do
        expect(result[1]).to eq(
          path: 'app/models/user.rb',
          start_line: 12,
          end_line: 12,
          annotation_level: 'warning',
          message: 'Line 12 is not covered by tests'
        )
      end
    end

    context 'when changed files have no uncovered lines' do
      let(:comparison) do
        { 'changed_files' => [
          { 'path' => 'app/models/user.rb', 'uncovered_lines' => [] }
        ] }
      end

      it { is_expected.to eq([]) }
    end
  end

  describe '#build_groups_table' do
    subject(:result) { report.build_groups_table(groups) }

    context 'when groups are empty' do
      let(:groups) { [] }

      it { is_expected.to be_nil }
    end

    context 'when groups are nil' do
      let(:groups) { nil }

      it { is_expected.to be_nil }
    end

    context 'when groups include baseline values' do
      let(:groups) do
        [{ 'name' => 'Models', 'current' => 78.1, 'baseline' => 77.8, 'delta' => 0.3 },
         { 'name' => 'Services', 'current' => 49.2, 'baseline' => 50.3, 'delta' => -1.1 }]
      end

      it do
        is_expected.to eq(<<~MARKDOWN.chomp)
          | Group | Coverage | Δ |
          |-------|----------|---|
          | Models | 78.1% | +0.3% ✅ |
          | Services | 49.2% | -1.1% ⚠️ |
        MARKDOWN
      end
    end

    context 'when groups do not include baseline values' do
      let(:groups) do
        [{ 'name' => 'Models', 'current' => 78.1 },
         { 'name' => 'Services', 'current' => 49.2 }]
      end

      it do
        is_expected.to eq(<<~MARKDOWN.chomp)
          | Group | Coverage |
          |-------|----------|
          | Models | 78.1% |
          | Services | 49.2% |
        MARKDOWN
      end
    end
  end

  describe '#build_pr_comment' do
    subject(:result) { report.build_pr_comment(coverage_result, comparison) }

    let(:coverage_result) do
      { 'total_coverage' => 54.2,
        'groups' => [{ 'name' => 'Models', 'coverage' => 78.1 }] }
    end

    context 'when comparison is absent' do
      let(:comparison) { nil }

      it do
        is_expected.to eq(<<~MARKDOWN)
          <!-- coverage-report-action -->
          ## 📊 Coverage Report

          **Overall: 54.2%**

          ### By Group

          | Group | Coverage |
          |-------|----------|
          | Models | 78.1% |

          📋 [View report & artifacts](https://github.com//actions/runs/)
        MARKDOWN
      end
    end

    context 'when comparison is present' do
      let(:comparison) do
        { 'overall' => { 'current' => 54.2, 'baseline' => 52.9, 'delta' => 1.3 },
          'groups' => [{ 'name' => 'Models', 'current' => 78.1, 'baseline' => 77.8, 'delta' => 0.3 }],
          'changed_files' => [
            { 'path' => 'app/models/user.rb', 'current' => 89.2, 'baseline' => 86.1, 'delta' => 3.1,
              'uncovered_lines' => [] }
          ] }
      end

      it do
        is_expected.to eq(<<~MARKDOWN)
          <!-- coverage-report-action -->
          ## 📊 Coverage Report

          **Overall: 54.2%** (+1.3% ✅ vs baseline)

          ### By Group

          | Group | Coverage | Δ |
          |-------|----------|---|
          | Models | 78.1% | +0.3% ✅ |

          ### Changed Files

          | File | Coverage | Δ | Uncovered Lines |
          |------|----------|---|-----------------|
          | app/models/user.rb | 89.2% | +3.1% ✅ | — |

          📋 [View report & artifacts](https://github.com//actions/runs/)
        MARKDOWN
      end
    end

    context 'when comparison is present but has no group or file deltas' do
      let(:comparison) do
        { 'overall' => { 'current' => 54.2, 'baseline' => 52.9, 'delta' => 1.3 },
          'groups' => [],
          'changed_files' => [] }
      end

      it do
        is_expected.to eq(<<~MARKDOWN)
          <!-- coverage-report-action -->
          ## 📊 Coverage Report

          **Overall: 54.2%** (+1.3% ✅ vs baseline)

          ### By Group

          | Group | Coverage |
          |-------|----------|
          | Models | 78.1% |

          📋 [View report & artifacts](https://github.com//actions/runs/)
        MARKDOWN
      end
    end
  end

  describe '#build_job_summary' do
    subject(:result) { report.build_job_summary(coverage_result, comparison) }

    let(:coverage_result) do
      { 'total_coverage' => 54.2,
        'groups' => [],
        'files' => [
          {
            'path' => 'app/models/user.rb',
            'coverage' => 89.2,
            'total_lines' => 112,
            'covered_lines' => 100,
            'uncovered_lines' => [12, 34, 35]
          }
        ] }
    end

    context 'when comparison is present' do
      let(:comparison) do
        { 'overall' => { 'current' => 54.2, 'baseline' => 52.9, 'delta' => 1.3 },
          'groups' => [],
          'changed_files' => [],
          'all_changed_coverage_files' => [
            { 'path' => 'app/helpers/helper.rb', 'current' => 45.0, 'baseline' => 48.0, 'delta' => -3.0 }
          ] }
      end

      it do
        is_expected.to eq(<<~MARKDOWN.chomp)
          ## 📊 Coverage Report — Full Details

          **Overall: 54.2%** (+1.3% ✅ vs baseline)

          ### All Files with Coverage Changes

          Files not touched in this PR but whose coverage was affected:

          | File | Coverage | Δ |
          |------|----------|---|
          | app/helpers/helper.rb | 45.0% | -3.0% ⚠️ |
        MARKDOWN
      end
    end

    context 'when comparison is absent' do
      let(:comparison) { nil }

      it do
        is_expected.to eq(<<~MARKDOWN.chomp)
          ## 📊 Coverage Report — Full Details

          **Overall: 54.2%**

          ### All Covered Files

          | File | Coverage | Covered / Total | Uncovered Lines |
          |------|----------|-----------------|-----------------|
          | app/models/user.rb | 89.2% | 100 / 112 | 12, 34-35 |
        MARKDOWN
      end
    end

    context 'when comparison is present but has no detailed sections' do
      let(:comparison) do
        {
          'overall' => { 'current' => 54.2, 'baseline' => 54.2, 'delta' => 0.0 },
          'groups' => [],
          'changed_files' => [],
          'all_changed_coverage_files' => []
        }
      end

      it do
        is_expected.to eq(<<~MARKDOWN.chomp)
          ## 📊 Coverage Report — Full Details

          **Overall: 54.2%** (+0.0% vs baseline)

          ### All Covered Files

          | File | Coverage | Covered / Total | Uncovered Lines |
          |------|----------|-----------------|-----------------|
          | app/models/user.rb | 89.2% | 100 / 112 | 12, 34-35 |
        MARKDOWN
      end
    end
  end

  describe '#no_comparison_sections' do
    subject(:result) { report.send(:no_comparison_sections, coverage_result, include_all_files: include_all_files) }

    let(:coverage_result) do
      {
        'groups' => [{ 'name' => 'Models', 'coverage' => 50.0 }],
        'files' => [{ 'path' => 'a.rb', 'coverage' => 100.0, 'covered_lines' => 1, 'total_lines' => 1,
                      'uncovered_lines' => [] }]
      }
    end

    context 'when including all files' do
      let(:include_all_files) { true }

      it do
        is_expected.to eq(<<~MARKDOWN.chomp)
          ### By Group

          | Group | Coverage |
          |-------|----------|
          | Models | 50.0% |

          ### All Covered Files

          | File | Coverage | Covered / Total | Uncovered Lines |
          |------|----------|-----------------|-----------------|
          | a.rb | 100.0% | 1 / 1 | — |
        MARKDOWN
      end
    end

    context 'when excluding all files' do
      let(:include_all_files) { false }

      it do
        is_expected.to eq(<<~MARKDOWN.chomp)
          ### By Group

          | Group | Coverage |
          |-------|----------|
          | Models | 50.0% |
        MARKDOWN
      end
    end
  end

  describe '#build_changed_files_table' do
    subject(:result) { report.send(:build_changed_files_table, changed_files) }

    context 'when changed files are nil' do
      let(:changed_files) { nil }

      it { is_expected.to be_nil }
    end

    context 'when files include baseline data' do
      let(:changed_files) do
        [{ 'path' => 'a.rb', 'current' => 50.0, 'baseline' => 40.0, 'delta' => 10.0, 'uncovered_lines' => [2] }]
      end

      it do
        is_expected.to eq(<<~MARKDOWN.chomp)
          | File | Coverage | Δ | Uncovered Lines |
          |------|----------|---|-----------------|
          | a.rb | 50.0% | +10.0% ✅ | 2 |
        MARKDOWN
      end
    end

    context 'when files do not include baseline data' do
      let(:changed_files) { [{ 'path' => 'b.rb', 'current' => 50.0, 'uncovered_lines' => [3] }] }

      it do
        is_expected.to eq(<<~MARKDOWN.chomp)
          | File | Coverage | Uncovered Lines |
          |------|----------|-----------------|
          | b.rb | 50.0% | 3 |
        MARKDOWN
      end
    end

    context 'when files are new and have no baseline data' do
      let(:changed_files) do
        [
          { 'path' => 'new_file_1.rb', 'current' => 85.0, 'uncovered_lines' => [5, 6] },
          { 'path' => 'new_file_2.rb', 'current' => 92.3, 'uncovered_lines' => [] }
        ]
      end

      it do
        is_expected.to eq(<<~MARKDOWN.chomp)
          | File | Coverage | Uncovered Lines |
          |------|----------|-----------------|
          | new_file_1.rb | 85.0% | 5-6 |
          | new_file_2.rb | 92.3% | — |
        MARKDOWN
      end
    end
  end

  describe '#build_all_changed_table' do
    subject(:result) { report.send(:build_all_changed_table, all_changed) }

    context 'when files are nil' do
      let(:all_changed) { nil }

      it { is_expected.to be_nil }
    end

    context 'when files have coverage changes' do
      let(:all_changed) { [{ 'path' => 'a.rb', 'current' => 40.0, 'delta' => -1.0 }] }

      it do
        is_expected.to eq(<<~MARKDOWN.chomp)
          | File | Coverage | Δ |
          |------|----------|---|
          | a.rb | 40.0% | -1.0% ⚠️ |
        MARKDOWN
      end
    end
  end

  describe '#build_all_files_table' do
    subject(:result) { report.send(:build_all_files_table, files) }

    context 'when files are empty' do
      let(:files) { [] }

      it { is_expected.to be_nil }
    end

    context 'when files have coverage details' do
      let(:files) do
        [{ 'path' => 'a.rb', 'coverage' => 40.0, 'covered_lines' => 2, 'total_lines' => 5,
           'uncovered_lines' => [3, 4] }]
      end

      it do
        is_expected.to eq(<<~MARKDOWN.chomp)
          | File | Coverage | Covered / Total | Uncovered Lines |
          |------|----------|-----------------|-----------------|
          | a.rb | 40.0% | 2 / 5 | 3-4 |
        MARKDOWN
      end
    end

    context 'when files include baseline data' do
      let(:files) do
        [{ 'path' => 'a.rb', 'coverage' => 40.0, 'baseline' => 41.0, 'delta' => -1.0,
           'covered_lines' => 2, 'total_lines' => 5, 'uncovered_lines' => [3, 4] }]
      end

      it do
        is_expected.to eq(<<~MARKDOWN.chomp)
          | File | Coverage | Δ | Covered / Total | Uncovered Lines |
          |------|----------|---|-----------------|-----------------|
          | a.rb | 40.0% | -1.0% ⚠️ | 2 / 5 | 3-4 |
        MARKDOWN
      end
    end
  end

  describe '#group_consecutive' do
    subject(:result) { report.send(:group_consecutive, sorted_lines) }

    context 'when multiple ranges are present' do
      let(:sorted_lines) { [1, 2, 3, 8, 10, 11] }

      it { is_expected.to eq([[1, 2, 3], [8], [10, 11]]) }
    end

    context 'when a single line is present' do
      let(:sorted_lines) { [5] }

      it { is_expected.to eq([[5]]) }
    end
  end

  describe '#ranges_to_annotations' do
    subject(:result) { report.send(:ranges_to_annotations, file_path, uncovered_lines) }

    let(:file_path) { 'a.rb' }

    context 'when there are no uncovered lines' do
      let(:uncovered_lines) { [] }

      it { is_expected.to eq([]) }
    end

    context 'when uncovered lines include ranges and single lines' do
      let(:uncovered_lines) { [2, 3, 6] }
      let(:first_annotation) { result.first }
      let(:last_annotation) { result.last }

      it 'creates one annotation per range' do
        expect(result.size).to eq(2)
      end

      it 'formats the first range message' do
        expect(first_annotation[:message]).to eq('Lines 2-3 are not covered by tests')
      end

      it 'formats the trailing single-line message' do
        expect(last_annotation[:message]).to eq('Line 6 is not covered by tests')
      end
    end
  end

  describe '#build_annotation' do
    subject(:result) { report.send(:build_annotation, file_path, range) }

    let(:file_path) { 'a.rb' }

    context 'when the range spans a single line' do
      let(:range) { { start: 4, end: 4 } }

      it 'builds a single-line message' do
        expect(result[:message]).to eq('Line 4 is not covered by tests')
      end
    end

    context 'when the range spans multiple lines' do
      let(:range) { { start: 4, end: 9 } }

      it 'builds a range message' do
        expect(result[:message]).to eq('Lines 4-9 are not covered by tests')
      end
    end
  end

  describe '#determine_conclusion' do
    subject(:result) { report.send(:determine_conclusion, coverage_result, comparison) }

    context 'when total coverage is below the threshold' do
      let(:coverage_result) { { 'total_coverage' => 70.0 } }
      let(:comparison) { nil }

      before do
        ENV['MIN_COVERAGE'] = '75'
      end

      it { is_expected.to eq('neutral') }
    end

    context 'when coverage meets the threshold but delta is negative' do
      let(:coverage_result) { { 'total_coverage' => 80.0 } }
      let(:comparison) { { 'overall' => { 'delta' => -0.1 } } }

      before do
        ENV['MIN_COVERAGE'] = '75'
      end

      it { is_expected.to eq('neutral') }
    end

    context 'when coverage meets the threshold and delta is positive' do
      let(:coverage_result) { { 'total_coverage' => 80.0 } }
      let(:comparison) { { 'overall' => { 'delta' => 0.1 } } }

      before do
        ENV['MIN_COVERAGE'] = '75'
      end

      it { is_expected.to eq('success') }
    end

    context 'when coverage meets the threshold but delta is strongly negative' do
      let(:coverage_result) { { 'total_coverage' => 80.0 } }
      let(:comparison) { { 'overall' => { 'delta' => -5.2 } } }

      before do
        ENV['MIN_COVERAGE'] = '50'
      end

      it { is_expected.to eq('neutral') }
    end
  end

  describe '#check_run_summary' do
    subject(:result) { report.send(:check_run_summary, coverage_result, comparison) }

    let(:coverage_result) { { 'total_coverage' => 80.12 } }

    context 'when comparison data is present' do
      let(:comparison) { { 'overall' => { 'delta' => 1.25 } } }

      it { is_expected.to eq('Coverage: 80.1% (+1.2% vs baseline)') }
    end

    context 'when comparison data is absent' do
      let(:comparison) { nil }

      it { is_expected.to eq('Coverage: 80.1%') }
    end
  end

  describe '#filter_annotations' do
    subject(:result) { report.send(:filter_annotations, annotations) }

    let(:annotations) { [{ path: 'a.rb' }] }

    context 'when annotations are disabled' do
      before do
        ENV['ANNOTATIONS'] = 'false'
      end

      it { is_expected.to eq([]) }
    end

    context 'when annotations are enabled' do
      before do
        report.instance_variable_set(:@annotations_enabled, nil)
        ENV['ANNOTATIONS'] = 'true'
      end

      it { is_expected.to eq(annotations) }
    end
  end

  describe '#submit_check_run' do
    subject(:result) { report.send(:submit_check_run, check_name, sha, conclusion, summary, annotations) }

    let(:client) { instance_double(Octokit::Client) }
    let(:check_run) { double('check_run', id: 123) }
    let(:check_name) { 'Coverage Report' }
    let(:sha) { 'abc123' }
    let(:conclusion) { 'success' }
    let(:summary) { 'Summary' }
    let(:annotations) do
      (1..55).map do |i|
        { path: 'a.rb', start_line: i, end_line: i, annotation_level: 'warning', message: "m#{i}" }
      end
    end

    before do
      allow(report).to receive(:github_client).and_return(client)
      allow(client).to receive(:create_check_run).and_return(check_run)
      ENV['GITHUB_REPOSITORY'] = 'org/repo'
      ENV['GITHUB_SHA'] = sha
    end

    it { is_expected.to eq(123) }

    it 'creates a check run' do
      result

      expect(client).to have_received(:create_check_run)
    end
  end

  describe '#submit_remaining_annotations' do
    subject(:submit_remaining) { report.send(:submit_remaining_annotations, check_run_id, summary, annotations) }

    let(:client) { instance_double(Octokit::Client) }
    let(:check_run_id) { 123 }
    let(:summary) { 'Summary' }
    let(:annotations) do
      (1..55).map do |i|
        { path: 'a.rb', start_line: i, end_line: i, annotation_level: 'warning', message: "m#{i}" }
      end
    end

    before do
      allow(report).to receive(:github_client).and_return(client)
      allow(client).to receive(:update_check_run)
      ENV['GITHUB_REPOSITORY'] = 'org/repo'
    end

    it 'submits remaining annotation batches' do
      submit_remaining

      expect(client).to have_received(:update_check_run).at_least(:once)
    end
  end

  describe '#create_check_run' do
    subject(:create_check_run) { report.send(:create_check_run, annotations, coverage_result, comparison) }

    let(:annotations) { [] }
    let(:coverage_result) { { 'total_coverage' => 100.0 } }
    let(:comparison) { nil }

    before do
      allow(report).to receive(:determine_conclusion).and_return('success')
      allow(report).to receive(:check_run_summary).and_return('Summary')
      allow(report).to receive(:filter_annotations).and_return([])
      allow(report).to receive(:submit_check_run).and_return(1)
      allow(report).to receive(:submit_remaining_annotations)
    end

    context 'when check run creation succeeds' do
      before do
        create_check_run
      end

      it 'submits the initial check run' do
        expect(report).to have_received(:submit_check_run)
      end
    end

    context 'when the GitHub API raises an error' do
      before do
        allow(report).to receive(:submit_check_run).and_raise(Octokit::NotFound)
      end

      it 'swallows the exception' do
        expect { create_check_run }.not_to raise_error
      end
    end
  end

  describe '#write_job_summary' do
    subject(:write_summary) { report.send(:write_job_summary, markdown) }

    let(:markdown) { 'hello' }

    around do |example|
      Dir.mktmpdir do |dir|
        @tmpdir = dir
        example.run
      end
    end

    let(:summary_path) { File.join(@tmpdir, 'summary.md') }

    context 'when the summary path is configured' do
      before do
        ENV['GITHUB_STEP_SUMMARY'] = summary_path
      end

      it 'writes the markdown to disk' do
        write_summary

        expect(File.read(summary_path)).to eq('hello')
      end
    end

    context 'when the summary path is blank' do
      before do
        ENV['GITHUB_STEP_SUMMARY'] = summary_path
        report.instance_variable_set(:@step_summary_path, nil)
        ENV['GITHUB_STEP_SUMMARY'] = ''
      end

      it 'does not raise an error' do
        expect { write_summary }.not_to raise_error
      end
    end
  end

  describe '#current_pr_number' do
    subject(:result) { report.send(:current_pr_number) }

    context 'when the event file contains a pull request' do
      around do |example|
        Dir.mktmpdir do |dir|
          @event_path = File.join(dir, 'event.json')
          File.write(@event_path, JSON.generate({ 'pull_request' => { 'number' => 77 } }))
          example.run
        end
      end

      before do
        ENV['GITHUB_EVENT_PATH'] = @event_path
      end

      it { is_expected.to eq(77) }
    end

    context 'when the event file is unavailable' do
      it { is_expected.to be_nil }
    end
  end

  describe '#find_existing_comment' do
    subject(:result) { report.send(:find_existing_comment, pr_number) }

    let(:pr_number) { 12 }
    let(:comment1) { double('comment_1', body: 'hello') }
    let(:comment2) { double('comment_2', body: "x #{SimpleCovDelta::Report::COMMENT_MARKER} y") }
    let(:client) { instance_double(Octokit::Client, issue_comments: [comment1, comment2]) }

    before do
      allow(report).to receive(:github_client).and_return(client)
      ENV['GITHUB_REPOSITORY'] = 'org/repo'
    end

    it { is_expected.to eq(comment2) }
  end

  describe '#post_or_update_pr_comment' do
    subject(:post_comment) { report.send(:post_or_update_pr_comment, comment_body) }

    let(:comment_body) { 'body' }
    let(:client) { instance_double(Octokit::Client) }

    before do
      ENV['POST_COMMENT'] = 'true'
      ENV['GITHUB_REPOSITORY'] = 'org/repo'
      allow(report).to receive(:github_client).and_return(client)
    end

    context 'when an existing sticky comment is found' do
      let(:existing_comment) { double('existing_comment', id: 5) }

      before do
        allow(report).to receive(:current_pr_number).and_return(10)
        allow(report).to receive(:find_existing_comment).and_return(existing_comment)
        allow(client).to receive(:update_comment)
      end

      it 'updates the existing comment' do
        post_comment

        expect(client).to have_received(:update_comment).with('org/repo', 5, 'body')
      end
    end

    context 'when no sticky comment is found' do
      before do
        allow(report).to receive(:current_pr_number).and_return(10)
        allow(report).to receive(:find_existing_comment).and_return(nil)
        allow(client).to receive(:add_comment)
      end

      it 'creates a new comment' do
        post_comment

        expect(client).to have_received(:add_comment).with('org/repo', 10, 'body')
      end
    end

    context 'when comment posting is disabled' do
      before do
        ENV['POST_COMMENT'] = 'false'
        report.instance_variable_set(:@post_comment_enabled, nil)
      end

      it 'does not raise an error' do
        expect { post_comment }.not_to raise_error
      end
    end

    context 'when there is no pull request number' do
      before do
        report.instance_variable_set(:@post_comment_enabled, nil)
        allow(report).to receive(:current_pr_number).and_return(nil)
      end

      it 'does not raise an error' do
        expect { post_comment }.not_to raise_error
      end
    end
  end

  describe '#run_url_link' do
    subject(:result) { report.send(:run_url_link) }

    context 'when run_url is nil' do
      before do
        allow(report).to receive(:run_url).and_return(nil)
      end

      it { is_expected.to be_nil }
    end

    context 'when run_url is empty' do
      before do
        allow(report).to receive(:run_url).and_return('')
      end

      it { is_expected.to be_nil }
    end
  end

  describe '#load_coverage_result' do
    subject(:result) { report.send(:load_coverage_result) }

    around do |example|
      Dir.mktmpdir do |dir|
        @coverage_dir = dir
        ENV['COVERAGE_PATH'] = dir
        example.run
      end
    end

    context 'when the coverage result file exists' do
      before do
        File.write(File.join(@coverage_dir, 'coverage_result.json'), JSON.generate({ total_coverage: 1.0 }))
      end

      it { is_expected.to eq('total_coverage' => 1.0) }
    end

    context 'when the coverage result file is missing' do
      it 'aborts the process' do
        expect { result }.to raise_error(SystemExit)
      end
    end
  end

  describe '#load_comparison' do
    subject(:result) { report.send(:load_comparison) }

    around do |example|
      Dir.mktmpdir do |dir|
        @coverage_dir = dir
        ENV['COVERAGE_PATH'] = dir
        example.run
      end
    end

    context 'when the comparison file exists' do
      before do
        File.write(File.join(@coverage_dir, 'comparison.json'), JSON.generate({ overall: { delta: 0.0 } }))
      end

      it { is_expected.to eq('overall' => { 'delta' => 0.0 }) }
    end

    context 'when the comparison file is missing' do
      it { is_expected.to be_nil }
    end
  end

  describe '#run' do
    subject(:run_report) { report.run }

    let(:coverage_result) { { 'total_coverage' => 50.0, 'groups' => [], 'files' => [] } }
    let(:comparison) { nil }

    before do
      allow(report).to receive(:load_coverage_result).and_return(coverage_result)
      allow(report).to receive(:load_comparison).and_return(comparison)
      allow(report).to receive(:build_annotations).and_return([])
      allow(report).to receive(:create_check_run)
      allow(report).to receive(:build_job_summary).and_return('summary')
      allow(report).to receive(:write_job_summary)
      allow(report).to receive(:build_pr_comment).and_return('comment')
      allow(report).to receive(:post_or_update_pr_comment)

      run_report
    end

    it 'creates the check run' do
      expect(report).to have_received(:create_check_run)
    end

    it 'writes the job summary' do
      expect(report).to have_received(:write_job_summary).with('summary')
    end

    it 'posts or updates the PR comment' do
      expect(report).to have_received(:post_or_update_pr_comment).with('comment')
    end
  end
end

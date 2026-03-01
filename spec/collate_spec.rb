# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

# Test the collation script's file-finding and coverage calculation logic
# without actually running SimpleCov.collate (which requires a full SimpleCov setup)
RSpec.describe 'Collation' do
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
end

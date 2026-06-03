require_relative "../../lib/analyzers/todo_debt"
require "fileutils"
require "tmpdir"

RSpec.describe TodoDebtAnalyzer do
  subject { described_class.new }

  let(:fixture_path) do
    File.expand_path("../../test-fixtures/unhealthy-repo-ruby", __dir__)
  end

  it "has correct name" do
    expect(subject.name).to eq("todo-debt")
  end

  it "has a description" do
    expect(subject.description).to be_a(String)
    expect(subject.description).not_to be_empty
  end

  it "returns an AnalyzerResult with analyzer, findings, and score" do
    result = subject.run(fixture_path)
    expect(result.analyzer).to eq("todo-debt")
    expect(result.findings).to be_an(Array)
    expect(result.score).to be_between(0, 100)
  end

  context "against the unhealthy fixture" do
    let(:result) { subject.run(fixture_path) }
    let(:utils_findings) do
      result.findings.select { |f| f.file.include?("utils.rb") }
    end

    it "finds all 4 markers in lib/utils.rb" do
      messages = utils_findings.map(&:message).join(" | ").upcase
      expect(messages).to include("TODO")
      expect(messages).to include("FIXME")
      expect(messages).to include("HACK")
      expect(messages).to include("XXX")
      expect(utils_findings.size).to be >= 4
    end

    it "includes file path and line number on each finding" do
      utils_findings.each do |f|
        expect(f.file).to be_a(String)
        expect(f.line).to be_a(Integer)
        expect(f.line).to be > 0
        expect(f.message).to be_a(String)
        expect(f.message).not_to be_empty
      end
    end

    it "produces a score less than 100 due to outstanding debt" do
      expect(result.score).to be < 100
      expect(result.score).to be_between(0, 100)
    end

    it "assigns a severity to every finding" do
      result.findings.each do |f|
        expect(%i[info warning error]).to include(f.severity)
      end
    end
  end

  context "case-insensitive matching" do
    it "matches lowercase markers" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "a.rb"), "# todo: lowercase\n# Fixme: mixed\n")
        result = subject.run(dir)
        expect(result.findings.size).to be >= 2
      end
    end
  end

  context "directory exclusions" do
    it "excludes vendor/, node_modules/, and .git/" do
      Dir.mktmpdir do |dir|
        %w[vendor node_modules .git].each do |excluded|
          FileUtils.mkdir_p(File.join(dir, excluded))
          File.write(File.join(dir, excluded, "f.rb"), "# TODO: should not be flagged\n")
        end
        File.write(File.join(dir, "real.rb"), "# TODO: real one\n")

        result = subject.run(dir)
        files = result.findings.map(&:file)
        expect(files.none? { |f| f.include?("/vendor/") }).to be true
        expect(files.none? { |f| f.include?("/node_modules/") }).to be true
        expect(files.none? { |f| f.include?("/.git/") }).to be true
        expect(files.any? { |f| f.include?("real.rb") }).to be true
      end
    end
  end

  context "non-git repository" do
    it "does not crash when the repo is not a git repo" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "a.rb"), "# TODO: bare repo\n")
        expect { subject.run(dir) }.not_to raise_error
        result = subject.run(dir)
        expect(result.findings.size).to be >= 1
        expect(result.score).to be_between(0, 100)
      end
    end
  end

  context "scoring" do
    it "returns 100 when there are no TODO-like markers" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "clean.rb"), "# nothing to see here\ndef ok; end\n")
        result = subject.run(dir)
        expect(result.score).to eq(100)
        expect(result.findings).to be_empty
      end
    end

    it "clamps the score to 0..100 with many markers" do
      Dir.mktmpdir do |dir|
        lines = Array.new(50) { |i| "# TODO: item #{i}" }.join("\n")
        File.write(File.join(dir, "many.rb"), lines)
        result = subject.run(dir)
        expect(result.score).to be_between(0, 100)
      end
    end
  end
end

require_relative "../../lib/analyzers/dependency_staleness"
require "tmpdir"
require "fileutils"

RSpec.describe DependencyStalenessAnalyzer do
  subject { described_class.new }

  it "has the correct name" do
    expect(subject.name).to eq("dependency-staleness")
  end

  it "has a description" do
    expect(subject.description).to be_a(String)
    expect(subject.description).not_to be_empty
  end

  describe "when no Gemfile is present" do
    it "returns score 100 with no findings" do
      Dir.mktmpdir do |dir|
        result = subject.run(dir)
        expect(result.score).to eq(100)
        expect(result.findings).to be_empty
        expect(result.analyzer).to eq("dependency-staleness")
      end
    end
  end

  describe "against the unhealthy fixture" do
    let(:fixture_path) { File.expand_path("../../test-fixtures/unhealthy-repo-ruby", __dir__) }
    let(:result) { subject.run(fixture_path) }

    it "returns an AnalyzerResult" do
      expect(result.analyzer).to eq("dependency-staleness")
      expect(result.findings).to be_an(Array)
    end

    it "produces a score in the 0..100 range" do
      expect(result.score).to be_between(0, 100)
    end

    it "produces a score below 100 because old pinned gems are present" do
      expect(result.score).to be < 100
    end

    it "flags rails pinned to an old version" do
      rails_findings = result.findings.select { |f| f.message.include?("rails") }
      expect(rails_findings).not_to be_empty
    end

    it "flags nokogiri pinned to an old version" do
      nokogiri_findings = result.findings.select { |f| f.message.include?("nokogiri") }
      expect(nokogiri_findings).not_to be_empty
    end

    it "records the Gemfile path on each finding" do
      expect(result.findings).to all(have_attributes(file: end_with("Gemfile")))
    end
  end

  describe "when a gem has no version constraint" do
    it "flags it as a warning" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "Gemfile"), <<~GEMFILE)
          source "https://rubygems.org"

          gem "some_unpinned_gem"
        GEMFILE

        result = subject.run(dir)
        unpinned = result.findings.find { |f| f.message.include?("some_unpinned_gem") }
        expect(unpinned).not_to be_nil
        expect(unpinned.severity).to eq(:warning)
      end
    end
  end

  describe "when a known deprecated gem is declared" do
    it "flags it as an error" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "Gemfile"), <<~GEMFILE)
          source "https://rubygems.org"

          gem "therubyracer"
        GEMFILE

        result = subject.run(dir)
        deprecated = result.findings.find { |f| f.message.include?("therubyracer") }
        expect(deprecated).not_to be_nil
        expect(deprecated.severity).to eq(:error)
      end
    end
  end

  describe "when all gems are healthy and up-to-date" do
    it "returns score 100 with no findings" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "Gemfile"), <<~GEMFILE)
          source "https://rubygems.org"

          gem "rails", "~> 7.1"
          gem "nokogiri", "~> 1.16"
        GEMFILE

        result = subject.run(dir)
        expect(result.score).to eq(100)
        expect(result.findings).to be_empty
      end
    end
  end
end

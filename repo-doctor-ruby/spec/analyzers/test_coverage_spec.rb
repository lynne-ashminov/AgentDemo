require_relative "../../lib/analyzers/test_coverage"
require "fileutils"
require "tmpdir"

RSpec.describe TestCoverageAnalyzer do
  subject { described_class.new }

  it "has correct name" do
    expect(subject.name).to eq("test-coverage")
  end

  it "has a description" do
    expect(subject.description).to be_a(String)
    expect(subject.description).not_to be_empty
  end

  describe "running against the unhealthy fixture" do
    let(:fixture_path) do
      File.expand_path("../../test-fixtures/unhealthy-repo-ruby", __dir__)
    end
    let(:result) { subject.run(fixture_path) }

    it "returns an AnalyzerResult identifying test-coverage" do
      expect(result.analyzer).to eq("test-coverage")
      expect(result.findings).to be_an(Array)
      expect(result.score).to be_between(0, 100)
    end

    it "flags utils.rb, dead_module.rb, and main.rb as uncovered" do
      uncovered_files = result.findings.map(&:file)
      expect(uncovered_files).to include(a_string_matching(%r{lib/utils\.rb\z}))
      expect(uncovered_files).to include(a_string_matching(%r{lib/dead_module\.rb\z}))
      expect(uncovered_files).to include(a_string_matching(%r{lib/main\.rb\z}))
    end

    it "does not flag active_module.rb as uncovered" do
      uncovered_files = result.findings.map(&:file)
      expect(uncovered_files).not_to include(a_string_matching(%r{lib/active_module\.rb\z}))
    end

    it "uses :warning severity for uncovered files" do
      uncovered = result.findings.select { |f| f.file.end_with?(".rb") }
      expect(uncovered).not_to be_empty
      expect(uncovered.map(&:severity).uniq).to eq([:warning])
    end

    it "scores around 25% (1 of 4 files covered)" do
      expect(result.score).to be_between(20, 30)
    end
  end

  describe "with nested directories" do
    it "recognises spec/bar/baz_spec.rb as covering lib/bar/baz.rb" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib", "bar"))
        FileUtils.mkdir_p(File.join(dir, "spec", "bar"))
        File.write(File.join(dir, "lib", "bar", "baz.rb"), "module Baz; end")
        File.write(File.join(dir, "spec", "bar", "baz_spec.rb"), "# spec")

        result = subject.run(dir)
        uncovered = result.findings.select { |f| f.severity == :warning }
        expect(uncovered).to be_empty
        expect(result.score).to eq(100)
      end
    end

    it "flags a nested lib file with no matching nested spec" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib", "bar"))
        FileUtils.mkdir_p(File.join(dir, "spec"))
        File.write(File.join(dir, "lib", "bar", "baz.rb"), "module Baz; end")

        result = subject.run(dir)
        uncovered_files = result.findings.map(&:file)
        expect(uncovered_files).to include(a_string_matching(%r{lib/bar/baz\.rb\z}))
      end
    end
  end

  describe "when no spec/ directory exists" do
    it "emits an :error severity finding" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib", "foo.rb"), "module Foo; end")

        result = subject.run(dir)
        errors = result.findings.select { |f| f.severity == :error }
        expect(errors).not_to be_empty
      end
    end
  end

  describe "when lib/ directory is missing" do
    it "returns gracefully without crashing" do
      Dir.mktmpdir do |dir|
        expect { subject.run(dir) }.not_to raise_error
        result = subject.run(dir)
        expect(result.score).to be_between(0, 100)
      end
    end
  end

  describe "with full coverage" do
    it "scores 100 when every lib file has a spec" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        FileUtils.mkdir_p(File.join(dir, "spec"))
        File.write(File.join(dir, "lib", "foo.rb"), "module Foo; end")
        File.write(File.join(dir, "spec", "foo_spec.rb"), "# spec")

        result = subject.run(dir)
        expect(result.score).to eq(100)
      end
    end
  end

  it "score is clamped to 0..100" do
    result = subject.run(Dir.pwd)
    expect(result.score).to be_between(0, 100)
  end
end

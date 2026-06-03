require_relative "../../lib/analyzers/dead_code"
require "fileutils"
require "tmpdir"

RSpec.describe DeadCodeAnalyzer do
  subject { described_class.new }

  it "has correct name" do
    expect(subject.name).to eq("dead-code")
  end

  it "has a description" do
    expect(subject.description).to be_a(String)
    expect(subject.description).not_to be_empty
  end

  it "returns an AnalyzerResult with score between 0 and 100" do
    Dir.mktmpdir do |dir|
      result = subject.run(dir)
      expect(result.analyzer).to eq("dead-code")
      expect(result.score).to be_between(0, 100)
      expect(result.findings).to be_an(Array)
    end
  end

  context "when repo has no lib/ directory" do
    it "returns score 100 with no findings" do
      Dir.mktmpdir do |dir|
        result = subject.run(dir)
        expect(result.score).to eq(100)
        expect(result.findings).to be_empty
      end
    end
  end

  context "against the unhealthy-repo-ruby fixture" do
    let(:fixture_path) do
      File.expand_path("../../test-fixtures/unhealthy-repo-ruby", __dir__)
    end

    let(:result) { subject.run(fixture_path) }

    it "flags dead_module.rb as dead code" do
      flagged = result.findings.map(&:file)
      expect(flagged.any? { |f| f.end_with?("dead_module.rb") }).to be true
    end

    it "does NOT flag main.rb (entry point)" do
      flagged = result.findings.map(&:file)
      expect(flagged.none? { |f| f.end_with?("main.rb") }).to be true
    end

    it "does NOT flag active_module.rb (required by main)" do
      flagged = result.findings.map(&:file)
      expect(flagged.none? { |f| f.end_with?("active_module.rb") }).to be true
    end

    it "produces a score less than 100" do
      expect(result.score).to be < 100
      expect(result.score).to be_between(0, 100)
    end

    it "uses :warning severity for dead code findings" do
      dead = result.findings.find { |f| f.file.end_with?("dead_module.rb") }
      expect(dead.severity).to eq(:warning)
    end
  end

  context "when every file is referenced" do
    it "returns score 100" do
      Dir.mktmpdir do |dir|
        lib_dir = File.join(dir, "lib")
        FileUtils.mkdir_p(lib_dir)
        File.write(File.join(lib_dir, "main.rb"), <<~RUBY)
          require_relative "helper"
          puts Helper.hi if __FILE__ == $0
        RUBY
        File.write(File.join(lib_dir, "helper.rb"), <<~RUBY)
          module Helper
            def self.hi = "hi"
          end
        RUBY

        result = subject.run(dir)
        expect(result.score).to eq(100)
        expect(result.findings).to be_empty
      end
    end
  end

  context "when files are unreferenced" do
    it "flags them and reduces the score" do
      Dir.mktmpdir do |dir|
        lib_dir = File.join(dir, "lib")
        FileUtils.mkdir_p(lib_dir)
        File.write(File.join(lib_dir, "main.rb"), <<~RUBY)
          require_relative "used"
          if __FILE__ == $0
            Used.do_it
          end
        RUBY
        File.write(File.join(lib_dir, "used.rb"), "module Used; def self.do_it = nil; end")
        File.write(File.join(lib_dir, "orphan.rb"), "module Orphan; end")
        File.write(File.join(lib_dir, "stray.rb"), "module Stray; end")

        result = subject.run(dir)
        flagged = result.findings.map { |f| File.basename(f.file) }
        expect(flagged).to include("orphan.rb", "stray.rb")
        expect(flagged).not_to include("main.rb", "used.rb")
        expect(result.score).to be < 100
        expect(result.score).to be_between(0, 100)
      end
    end
  end

  context "when bin/ scripts require lib files" do
    it "treats lib files required from bin/ as live" do
      Dir.mktmpdir do |dir|
        lib_dir = File.join(dir, "lib")
        bin_dir = File.join(dir, "bin")
        FileUtils.mkdir_p(lib_dir)
        FileUtils.mkdir_p(bin_dir)
        File.write(File.join(lib_dir, "core.rb"), "module Core; end")
        File.write(File.join(bin_dir, "tool"), <<~RUBY)
          #!/usr/bin/env ruby
          require_relative "../lib/core"
        RUBY

        result = subject.run(dir)
        flagged = result.findings.map { |f| File.basename(f.file) }
        expect(flagged).not_to include("core.rb")
      end
    end
  end

  context "when require_relative paths include subdirectories" do
    it "resolves nested requires correctly" do
      Dir.mktmpdir do |dir|
        lib_dir = File.join(dir, "lib")
        sub = File.join(lib_dir, "sub")
        FileUtils.mkdir_p(sub)
        File.write(File.join(lib_dir, "main.rb"), <<~RUBY)
          require_relative "sub/inner"
          if __FILE__ == $0
            Inner.run
          end
        RUBY
        File.write(File.join(sub, "inner.rb"), "module Inner; def self.run = nil; end")

        result = subject.run(dir)
        expect(result.findings).to be_empty
        expect(result.score).to eq(100)
      end
    end
  end
end

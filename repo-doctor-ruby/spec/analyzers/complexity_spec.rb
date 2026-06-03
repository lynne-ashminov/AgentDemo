require_relative "../../lib/analyzers/complexity"
require "fileutils"
require "tmpdir"

RSpec.describe ComplexityAnalyzer do
  subject { described_class.new }

  it "has correct name" do
    expect(subject.name).to eq("complexity")
  end

  it "has a description" do
    expect(subject.description).to be_a(String)
    expect(subject.description).not_to be_empty
  end

  context "against the unhealthy fixture (small files)" do
    let(:fixture_path) do
      File.expand_path("../../test-fixtures/unhealthy-repo-ruby", __dir__)
    end

    it "returns an AnalyzerResult with score in 0..100" do
      result = subject.run(fixture_path)
      expect(result.analyzer).to eq("complexity")
      expect(result.score).to be_between(0, 100)
      expect(result.findings).to be_an(Array)
    end

    it "scores high because all fixture files are short" do
      result = subject.run(fixture_path)
      expect(result.score).to be_between(90, 100)
    end
  end

  context "with synthesized files" do
    around do |example|
      Dir.mktmpdir do |dir|
        @repo = dir
        example.run
      end
    end

    def write(rel, content)
      path = File.join(@repo, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
      path
    end

    it "flags files exceeding 200 lines with severity :warning" do
      body = (["puts 'x'"] * 250).join("\n")
      write("lib/big.rb", body)

      result = subject.run(@repo)

      line_findings = result.findings.select { |f| f.message.include?("lines") }
      expect(line_findings).not_to be_empty
      flagged = line_findings.find { |f| f.file.end_with?("big.rb") }
      expect(flagged).not_to be_nil
      expect(flagged.severity).to eq(:warning)
    end

    it "uses :error severity for files exceeding 500 lines" do
      body = (["puts 'x'"] * 600).join("\n")
      write("lib/huge.rb", body)

      result = subject.run(@repo)

      flagged = result.findings.find { |f| f.file.end_with?("huge.rb") && f.message.include?("lines") }
      expect(flagged).not_to be_nil
      expect(flagged.severity).to eq(:error)
    end

    it "flags files with more than 15 methods with severity :warning" do
      methods = (1..16).map { |i| "def m#{i}\n  1\nend" }.join("\n")
      write("lib/many_methods.rb", methods)

      result = subject.run(@repo)

      method_count_findings = result.findings.select do |f|
        f.file.end_with?("many_methods.rb") && f.message.include?("methods")
      end
      expect(method_count_findings).not_to be_empty
      expect(method_count_findings.first.severity).to eq(:warning)
    end

    it "uses :error severity for files exceeding 30 methods" do
      methods = (1..31).map { |i| "def m#{i}\n  1\nend" }.join("\n")
      write("lib/way_too_many.rb", methods)

      result = subject.run(@repo)

      flagged = result.findings.find do |f|
        f.file.end_with?("way_too_many.rb") && f.message.include?("methods")
      end
      expect(flagged).not_to be_nil
      expect(flagged.severity).to eq(:error)
    end

    it "flags individual methods exceeding 30 lines with severity :warning" do
      body_lines = ["def long_one"] + (["  x = 1"] * 35) + ["end"]
      write("lib/long_method.rb", body_lines.join("\n"))

      result = subject.run(@repo)

      flagged = result.findings.find do |f|
        f.file.end_with?("long_method.rb") && f.message.downcase.include?("method")
      end
      expect(flagged).not_to be_nil
      expect(flagged.severity).to eq(:warning)
    end

    it "counts class methods (def self.foo) as methods" do
      body = (1..16).map { |i| "def self.cm#{i}\n  1\nend" }.join("\n")
      write("lib/class_methods.rb", body)

      result = subject.run(@repo)

      flagged = result.findings.find do |f|
        f.file.end_with?("class_methods.rb") && f.message.include?("methods")
      end
      expect(flagged).not_to be_nil
    end

    it "excludes vendor/ and .git/ directories" do
      big_body = (["puts 'x'"] * 300).join("\n")
      write("vendor/big.rb", big_body)
      write(".git/big.rb", big_body)

      result = subject.run(@repo)

      offenders = result.findings.select { |f| f.file.include?("vendor/") || f.file.include?(".git/") }
      expect(offenders).to be_empty
    end

    it "scores 100 when there are no .rb files" do
      result = subject.run(@repo)
      expect(result.score).to eq(100)
    end

    it "produces a lower score when files violate thresholds" do
      body = (["puts 'x'"] * 250).join("\n")
      write("lib/over.rb", body)
      write("lib/ok.rb", "puts 'ok'")

      result = subject.run(@repo)
      expect(result.score).to be_between(0, 99)
    end

    it "clamps score to 0..100" do
      10.times do |i|
        write("lib/big#{i}.rb", (["puts 'x'"] * 600).join("\n"))
      end
      result = subject.run(@repo)
      expect(result.score).to be_between(0, 100)
    end
  end
end

require_relative "../../lib/analyzers/doc_health"
require "fileutils"
require "tmpdir"

RSpec.describe DocHealthAnalyzer do
  subject { described_class.new }

  it "has correct name" do
    expect(subject.name).to eq("doc-health")
  end

  it "has a description" do
    expect(subject.description).to be_a(String)
    expect(subject.description).not_to be_empty
  end

  describe "#run" do
    it "returns an AnalyzerResult with name, findings, and score" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "README.md"), "# Healthy\n")
        result = subject.run(dir)
        expect(result.analyzer).to eq("doc-health")
        expect(result.findings).to be_an(Array)
        expect(result.score).to be_between(0, 100)
      end
    end

    context "when README.md is missing" do
      it "produces an :error finding and a low score" do
        Dir.mktmpdir do |dir|
          result = subject.run(dir)
          missing_finding = result.findings.find { |f| f.message =~ /README/i }
          expect(missing_finding).not_to be_nil
          expect(missing_finding.severity).to eq(:error)
          expect(result.score).to be_between(0, 80)
        end
      end
    end

    context "when README has only valid content" do
      it "scores 100 with no findings" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "README.md"), "# Hello\n\nNo links here.\n")
          result = subject.run(dir)
          expect(result.findings).to be_empty
          expect(result.score).to eq(100)
        end
      end
    end

    context "when README has a working relative link" do
      it "does not flag the link" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "docs"))
          File.write(File.join(dir, "docs", "guide.md"), "# Guide")
          File.write(File.join(dir, "README.md"), "[Guide](./docs/guide.md)\n")
          result = subject.run(dir)
          expect(result.findings).to be_empty
          expect(result.score).to eq(100)
        end
      end
    end

    context "when README has a broken relative link" do
      it "flags the broken link with severity :warning" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "README.md"), "[Missing](./nope.md)\n")
          result = subject.run(dir)
          broken = result.findings.find { |f| f.message =~ /nope\.md/ }
          expect(broken).not_to be_nil
          expect(broken.severity).to eq(:warning)
          expect(result.score).to be < 100
        end
      end
    end

    context "when README has external (http/https) links" do
      it "does not flag external URLs" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "README.md"),
                     "[Anthropic](https://www.anthropic.com)\n[HTTP](http://example.com)\n")
          result = subject.run(dir)
          expect(result.findings).to be_empty
          expect(result.score).to eq(100)
        end
      end
    end

    context "when a markdown file has merge conflict markers" do
      it "flags them with severity :error" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "README.md"), <<~MD)
            # Title

            <<<<<<< HEAD
            ours
            =======
            theirs
            >>>>>>> branch
          MD
          result = subject.run(dir)
          conflict = result.findings.find { |f| f.message =~ /conflict/i }
          expect(conflict).not_to be_nil
          expect(conflict.severity).to eq(:error)
          expect(result.score).to be < 100
        end
      end
    end

    context "when a non-README markdown file has conflict markers" do
      it "still flags them" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "README.md"), "# Ok\n")
          FileUtils.mkdir_p(File.join(dir, "docs"))
          File.write(File.join(dir, "docs", "guide.md"), <<~MD)
            <<<<<<< HEAD
            a
            =======
            b
            >>>>>>> x
          MD
          result = subject.run(dir)
          conflict = result.findings.find { |f| f.file.include?("guide.md") && f.message =~ /conflict/i }
          expect(conflict).not_to be_nil
          expect(conflict.severity).to eq(:error)
        end
      end
    end

    context "against the unhealthy fixture" do
      let(:fixture_path) do
        File.expand_path("../../test-fixtures/unhealthy-repo-ruby", __dir__)
      end

      it "flags broken relative links in the README" do
        result = subject.run(fixture_path)
        broken_messages = result.findings.map(&:message).join("\n")
        expect(broken_messages).to match(/architecture\.md/)
        expect(broken_messages).to match(/CONTRIBUTING\.md/)
        expect(broken_messages).to match(/api\.md/)
        expect(broken_messages).to match(/setup\.md/)
      end

      it "flags merge conflict markers in the README" do
        result = subject.run(fixture_path)
        conflict = result.findings.find { |f| f.message =~ /conflict/i }
        expect(conflict).not_to be_nil
        expect(conflict.severity).to eq(:error)
      end

      it "scores below 100" do
        result = subject.run(fixture_path)
        expect(result.score).to be_between(0, 80)
      end
    end

    it "clamps score to the 0..100 range" do
      Dir.mktmpdir do |dir|
        20.times { |i| File.write(File.join(dir, "doc#{i}.md"), "<<<<<<< HEAD\na\n=======\nb\n>>>>>>> x\n") }
        result = subject.run(dir)
        expect(result.score).to be_between(0, 100)
      end
    end
  end
end

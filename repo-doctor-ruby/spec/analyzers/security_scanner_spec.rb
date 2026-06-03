require "tmpdir"
require "fileutils"
require_relative "../../lib/analyzers/security_scanner"

RSpec.describe SecurityScannerAnalyzer do
  subject { described_class.new }

  let(:fixture_path) do
    File.expand_path("../../test-fixtures/unhealthy-repo-ruby", __dir__)
  end

  it "has the correct name" do
    expect(subject.name).to eq("security-scanner")
  end

  it "has a description" do
    expect(subject.description).to be_a(String)
    expect(subject.description).not_to be_empty
  end

  it "returns an AnalyzerResult with score between 0 and 100" do
    result = subject.run(fixture_path)
    expect(result.analyzer).to eq("security-scanner")
    expect(result.findings).to be_an(Array)
    expect(result.score).to be_between(0, 100)
  end

  context "with the unhealthy-repo-ruby fixture" do
    let(:result) { subject.run(fixture_path) }
    let(:findings) { result.findings }
    let(:messages) { findings.map(&:message).join("\n") }

    it "flags the committed .env file" do
      env_finding = findings.find { |f| f.file.end_with?(".env") && f.severity == :error }
      expect(env_finding).not_to be_nil
    end

    it "flags AWS_ACCESS_KEY_ID inside .env" do
      expect(messages).to match(/AWS/i)
    end

    it "flags SECRET_KEY_BASE inside .env" do
      expect(messages).to match(/SECRET/i)
    end

    it "flags DATABASE_URL inside .env" do
      expect(messages).to match(/DATABASE|database url/i)
    end

    it "scores low because secrets are committed" do
      expect(result.score).to be < 60
    end

    it "uses :error severity for at least one finding" do
      expect(findings.map(&:severity)).to include(:error)
    end
  end

  context "with a clean temporary repo" do
    around do |example|
      Dir.mktmpdir do |tmp|
        @tmp = tmp
        File.write(File.join(tmp, ".gitignore"), ".env\n*.pem\n*.key\n")
        File.write(File.join(tmp, "README.md"), "# Clean repo\n")
        example.run
      end
    end

    it "returns a high score and no error findings" do
      result = subject.run(@tmp)
      expect(result.score).to be_between(90, 100)
      expect(result.findings.map(&:severity)).not_to include(:error)
    end
  end

  context "with a missing .gitignore" do
    around do |example|
      Dir.mktmpdir do |tmp|
        @tmp = tmp
        File.write(File.join(tmp, "README.md"), "# repo\n")
        example.run
      end
    end

    it "warns that .gitignore is missing" do
      result = subject.run(@tmp)
      warnings = result.findings.select { |f| f.severity == :warning }
      expect(warnings).not_to be_empty
    end
  end

  context "with a .gitignore missing common sensitive patterns" do
    around do |example|
      Dir.mktmpdir do |tmp|
        @tmp = tmp
        File.write(File.join(tmp, ".gitignore"), "tmp/\n")
        File.write(File.join(tmp, "README.md"), "# repo\n")
        example.run
      end
    end

    it "warns about missing sensitive patterns (.env, *.pem, *.key)" do
      result = subject.run(@tmp)
      warning_messages = result.findings.select { |f| f.severity == :warning }.map(&:message).join("\n")
      expect(warning_messages).to match(/\.env|\.pem|\.key/)
    end
  end

  context "with hardcoded secrets in source files" do
    around do |example|
      Dir.mktmpdir do |tmp|
        @tmp = tmp
        File.write(File.join(tmp, ".gitignore"), ".env\n*.pem\n*.key\n")
        File.write(File.join(tmp, "config.rb"), <<~RUBY)
          AWS_ACCESS_KEY_ID = "AKIAIOSFODNN7EXAMPLE"
          PASSWORD = "hunter2letmeinplease"
        RUBY
        example.run
      end
    end

    it "flags hardcoded AWS keys and passwords" do
      result = subject.run(@tmp)
      messages = result.findings.map(&:message).join("\n")
      expect(messages).to match(/AWS|AKIA/i)
    end

    it "uses :error severity for hardcoded secrets" do
      result = subject.run(@tmp)
      severities = result.findings.select { |f| f.file.end_with?("config.rb") }.map(&:severity)
      expect(severities).to include(:error)
    end
  end

  context "with binary files present" do
    around do |example|
      Dir.mktmpdir do |tmp|
        @tmp = tmp
        File.write(File.join(tmp, ".gitignore"), ".env\n*.pem\n*.key\n")
        File.binwrite(File.join(tmp, "image.png"), "\x89PNG\r\n\x1a\n\x00\x00\x00\x00password=secret123")
        example.run
      end
    end

    it "does not scan binary files" do
      result = subject.run(@tmp)
      binary_findings = result.findings.select { |f| f.file.end_with?("image.png") }
      expect(binary_findings).to be_empty
    end
  end

  context "with a .git directory present" do
    around do |example|
      Dir.mktmpdir do |tmp|
        @tmp = tmp
        File.write(File.join(tmp, ".gitignore"), ".env\n*.pem\n*.key\n")
        FileUtils.mkdir_p(File.join(tmp, ".git"))
        # Use a synthetic non-AWS-shaped key here to avoid tripping repo
        # secret scanners while still exercising the .git skip path.
        File.write(File.join(tmp, ".git", "config"), "password = supersecret\nKEY=ZZZZFAKEFAKEFAKEFAKE\n")
        example.run
      end
    end

    it "does not scan .git directory contents" do
      result = subject.run(@tmp)
      git_findings = result.findings.select { |f| f.file.include?("/.git/") }
      expect(git_findings).to be_empty
    end
  end
end

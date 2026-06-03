require "fileutils"
require "open3"
require "tmpdir"

require_relative "../../lib/analyzers/git_health"

RSpec.describe GitHealthAnalyzer do
  subject(:analyzer) { described_class.new }

  def run_git(*args, dir:)
    out, err, status = Open3.capture3("git", *args, chdir: dir)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?

    out
  end

  def init_repo(dir)
    run_git("init", "-q", "-b", "main", dir: dir)
    run_git("config", "user.email", "test@example.com", dir: dir)
    run_git("config", "user.name", "Test User", dir: dir)
    run_git("config", "commit.gpgsign", "false", dir: dir)
  end

  def commit(dir, message, date: nil)
    env = {}
    if date
      env["GIT_AUTHOR_DATE"] = date
      env["GIT_COMMITTER_DATE"] = date
    end
    _o, e, s = Open3.capture3(env, "git", "commit", "-q", "--allow-empty", "-m", message, chdir: dir)
    raise "git commit failed: #{e}" unless s.success?
  end

  it "has the correct name" do
    expect(analyzer.name).to eq("git-health")
  end

  it "has a description" do
    expect(analyzer.description).to be_a(String)
    expect(analyzer.description).not_to be_empty
  end

  describe "return shape" do
    it "returns an AnalyzerResult with score in 0..100" do
      Dir.mktmpdir do |dir|
        init_repo(dir)
        File.write(File.join(dir, "a.txt"), "hello\n")
        run_git("add", ".", dir: dir)
        commit(dir, "initial")

        result = analyzer.run(dir)
        expect(result.analyzer).to eq("git-health")
        expect(result.findings).to be_an(Array)
        expect(result.score).to be_between(0, 100).inclusive
      end
    end
  end

  describe "graceful behaviour" do
    it "does not crash on a non-git directory" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "x.txt"), "hi\n")
        expect { analyzer.run(dir) }.not_to raise_error
        result = analyzer.run(dir)
        expect(result.score).to be_between(0, 100).inclusive
      end
    end

    it "handles repos with no commits without crashing" do
      Dir.mktmpdir do |dir|
        init_repo(dir)
        expect { analyzer.run(dir) }.not_to raise_error
        result = analyzer.run(dir)
        expect(result.score).to be_between(0, 100).inclusive
      end
    end
  end

  describe "commit recency" do
    it "warns when no commits in the last 30 days" do
      Dir.mktmpdir do |dir|
        init_repo(dir)
        File.write(File.join(dir, "a.txt"), "x\n")
        run_git("add", ".", dir: dir)
        old_date = (Time.now - (60 * 24 * 60 * 60)).strftime("%Y-%m-%dT%H:%M:%S")
        commit(dir, "old commit", date: old_date)

        result = analyzer.run(dir)
        messages = result.findings.map(&:message).join("\n")
        expect(messages).to match(/no commits|stale|30 days|inactive/i)
      end
    end

    it "does not warn about recency when there is a recent commit" do
      Dir.mktmpdir do |dir|
        init_repo(dir)
        File.write(File.join(dir, "a.txt"), "x\n")
        run_git("add", ".", dir: dir)
        commit(dir, "recent commit")

        result = analyzer.run(dir)
        recency_messages = result.findings.map(&:message).grep(/no commits in the last 30/i)
        expect(recency_messages).to be_empty
      end
    end
  end

  describe "stale branches" do
    it "detects branches with no commits in the last 90 days" do
      Dir.mktmpdir do |dir|
        init_repo(dir)
        File.write(File.join(dir, "a.txt"), "x\n")
        run_git("add", ".", dir: dir)
        commit(dir, "main commit")

        # Create a stale branch with an old commit
        run_git("checkout", "-q", "-b", "stale-branch", dir: dir)
        File.write(File.join(dir, "b.txt"), "y\n")
        run_git("add", ".", dir: dir)
        old_date = (Time.now - (200 * 24 * 60 * 60)).strftime("%Y-%m-%dT%H:%M:%S")
        commit(dir, "stale work", date: old_date)
        run_git("checkout", "-q", "main", dir: dir)

        result = analyzer.run(dir)
        stale_messages = result.findings.map(&:message).grep(/stale/i)
        expect(stale_messages).not_to be_empty
        expect(stale_messages.join(" ")).to include("stale-branch")
      end
    end
  end

  describe "conflict markers" do
    it "flags conflict markers in tracked files as :error" do
      Dir.mktmpdir do |dir|
        init_repo(dir)
        File.write(File.join(dir, "README.md"), <<~MD)
          # Title

          <<<<<<< HEAD
          ours
          =======
          theirs
          >>>>>>> feature

          End.
        MD
        run_git("add", ".", dir: dir)
        commit(dir, "with conflict")

        result = analyzer.run(dir)
        conflicts = result.findings.select { |f| f.message =~ /conflict marker/i }
        expect(conflicts).not_to be_empty
        expect(conflicts.map(&:severity)).to all(eq(:error))
        expect(conflicts.first.file).to include("README.md")
        expect(conflicts.first.line).to be_a(Integer)
      end
    end

    it "scores below 100 when conflict markers exist" do
      Dir.mktmpdir do |dir|
        init_repo(dir)
        File.write(File.join(dir, "README.md"), "<<<<<<< HEAD\nfoo\n=======\nbar\n>>>>>>> x\n")
        run_git("add", ".", dir: dir)
        commit(dir, "with conflict")

        result = analyzer.run(dir)
        expect(result.score).to be < 100
      end
    end
  end

  describe "unhealthy fixture" do
    let(:fixture_path) do
      File.expand_path("../../test-fixtures/unhealthy-repo-ruby", __dir__)
    end

    it "flags conflict markers in the fixture README" do
      result = analyzer.run(fixture_path)
      conflicts = result.findings.select { |f| f.message =~ /conflict marker/i }
      expect(conflicts).not_to be_empty
      expect(conflicts.any? { |f| f.file.include?("README.md") }).to be true
    end

    it "scores less than 100 for the unhealthy fixture" do
      result = analyzer.run(fixture_path)
      expect(result.score).to be < 100
      expect(result.score).to be_between(0, 100).inclusive
    end
  end
end

require_relative "base"
require "open3"

class GitHealthAnalyzer < BaseAnalyzer
  STALE_COMMIT_DAYS = 30
  STALE_BRANCH_DAYS = 90
  CONFLICT_MARKER_REGEX = /^(<{7}|={7}|>{7})(\s|$)/.freeze
  SKIP_DIRS = %w[.git node_modules vendor].freeze

  def name = "git-health"
  def description = "Analyzes git history, branches, and conflict markers"

  def run(repo_path)
    findings = []
    score = 100

    findings.concat(conflict_marker_findings(repo_path))

    if git_repo?(repo_path)
      recency = recent_commit_finding(repo_path)
      findings << recency if recency
      findings.concat(stale_branch_findings(repo_path))
      uncommitted = uncommitted_changes_finding(repo_path)
      findings << uncommitted if uncommitted
    end

    score -= findings.sum { |f| penalty_for(f) }
    result(findings: findings, score: score)
  end

  private

  def penalty_for(finding)
    case finding.severity
    when :error then 20
    when :warning then 10
    else 0
    end
  end

  def git_repo?(repo_path)
    _out, _err, status = Open3.capture3(
      "git", "-C", repo_path, "rev-parse", "--is-inside-work-tree"
    )
    status.success?
  end

  def recent_commit_finding(repo_path)
    out, _err, status = Open3.capture3(
      "git", "-C", repo_path, "log", "-1", "--format=%ct"
    )
    return nil unless status.success?

    timestamp = out.strip
    return nil if timestamp.empty?

    age_days = ((Time.now.to_i - timestamp.to_i) / 86_400.0).floor
    return nil if age_days <= STALE_COMMIT_DAYS

    finding(
      file: repo_path,
      message: "No commits in the last #{STALE_COMMIT_DAYS} days (latest commit #{age_days} days ago)",
      severity: :warning
    )
  end

  def stale_branch_findings(repo_path)
    out, _err, status = Open3.capture3(
      "git", "-C", repo_path, "for-each-ref",
      "--format=%(refname:short)|%(committerdate:unix)",
      "refs/heads"
    )
    return [] unless status.success?

    now = Time.now.to_i
    out.each_line.filter_map do |line|
      name, ts = line.strip.split("|", 2)
      next if name.nil? || ts.nil? || ts.empty?

      age_days = ((now - ts.to_i) / 86_400.0).floor
      next if age_days <= STALE_BRANCH_DAYS

      finding(
        file: repo_path,
        message: "Stale branch '#{name}' (last commit #{age_days} days ago)",
        severity: :warning
      )
    end
  end

  def uncommitted_changes_finding(repo_path)
    out, _err, status = Open3.capture3(
      "git", "-C", repo_path, "status", "--porcelain"
    )
    return nil unless status.success?
    return nil if out.strip.empty?

    count = out.lines.size
    finding(
      file: repo_path,
      message: "#{count} uncommitted change#{count == 1 ? '' : 's'} in the working tree",
      severity: :info
    )
  end

  def conflict_marker_findings(repo_path)
    files = tracked_files(repo_path)
    files.flat_map { |relative| scan_for_conflict_markers(repo_path, relative) }
  end

  # Returns repo-relative paths. Falls back to a filesystem walk when the
  # directory is not a git repo, so the analyzer still flags conflict markers.
  def tracked_files(repo_path)
    if git_repo?(repo_path)
      out, _err, status = Open3.capture3(
        "git", "-C", repo_path, "ls-files"
      )
      return out.each_line.map(&:chomp) if status.success?
    end

    walk_files(repo_path)
  end

  def walk_files(dir, prefix = "")
    results = []
    return results unless File.directory?(dir)

    Dir.children(dir).each do |entry|
      next if SKIP_DIRS.include?(entry)

      full = File.join(dir, entry)
      relative = prefix.empty? ? entry : File.join(prefix, entry)
      if File.directory?(full)
        results.concat(walk_files(full, relative))
      else
        results << relative
      end
    end
    results
  end

  def scan_for_conflict_markers(repo_path, relative)
    full_path = File.join(repo_path, relative)
    return [] unless File.file?(full_path)
    return [] if binary?(full_path)

    findings = []
    File.foreach(full_path).with_index(1) do |line, lineno|
      next unless line =~ CONFLICT_MARKER_REGEX

      findings << finding(
        file: relative,
        line: lineno,
        message: "Conflict marker found: #{line.strip}",
        severity: :error
      )
    end
    findings
  rescue ArgumentError, Errno::EACCES
    # Skip files with invalid encoding or permission issues.
    []
  end

  def binary?(path)
    sample = File.binread(path, 1024)
    return false if sample.nil? || sample.empty?

    sample.include?("\x00")
  end
end

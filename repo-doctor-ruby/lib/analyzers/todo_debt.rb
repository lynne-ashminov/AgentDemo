require_relative "base"
require "open3"
require "date"

class TodoDebtAnalyzer < BaseAnalyzer
  MARKER_REGEX = /\b(TODO|FIXME|HACK|XXX)\b/i
  EXCLUDED_DIRS = %w[vendor node_modules .git].freeze
  WARNING_AGE_DAYS = 90
  ERROR_AGE_DAYS = 365
  SCORE_PENALTY_PER_MARKER = 5

  def name = "todo-debt"
  def description = "Finds TODO/FIXME/HACK/XXX comments and checks their age"

  def run(repo_path)
    findings = []
    git_repo = git_repo?(repo_path)

    each_source_file(repo_path) do |path|
      File.foreach(path).with_index(1) do |line, lineno|
        next unless line =~ MARKER_REGEX

        age_days = git_repo ? blame_age_days(repo_path, path, lineno) : nil
        findings << finding(
          file: path,
          line: lineno,
          severity: severity_for(age_days),
          message: build_message(line, age_days)
        )
      end
    end

    score = 100 - (findings.size * SCORE_PENALTY_PER_MARKER)
    result(findings: findings, score: score)
  end

  private

  def each_source_file(dir, &block)
    Dir.children(dir).each do |entry|
      next if EXCLUDED_DIRS.include?(entry)
      next if entry.start_with?(".")

      full_path = File.join(dir, entry)
      if File.directory?(full_path)
        each_source_file(full_path, &block)
      elsif text_file?(full_path)
        yield full_path
      end
    end
  rescue Errno::ENOENT, Errno::EACCES
    # Skip unreadable directories rather than crashing.
  end

  def text_file?(path)
    return false unless File.file?(path)
    return false if File.size(path).zero?

    # Sniff the first chunk for NUL bytes to skip binary files.
    sample = File.binread(path, 1024)
    !sample.include?("\x00")
  rescue Errno::ENOENT, Errno::EACCES
    false
  end

  def git_repo?(repo_path)
    _, status = Open3.capture2e("git", "-C", repo_path, "rev-parse", "--is-inside-work-tree")
    status.success?
  rescue StandardError
    false
  end

  def blame_age_days(repo_path, file_path, lineno)
    relative = file_path.sub(/\A#{Regexp.escape(repo_path)}\/?/, "")
    stdout, status = Open3.capture2e(
      "git", "-C", repo_path, "log", "-1", "--format=%at",
      "-L", "#{lineno},#{lineno}:#{relative}"
    )
    return nil unless status.success?

    timestamp = stdout.lines.map(&:strip).find { |l| l =~ /\A\d+\z/ }
    return nil unless timestamp

    ((Time.now - Time.at(timestamp.to_i)) / 86_400).to_i
  rescue StandardError
    nil
  end

  def severity_for(age_days)
    return :info if age_days.nil?
    return :error if age_days > ERROR_AGE_DAYS
    return :warning if age_days > WARNING_AGE_DAYS

    :info
  end

  def build_message(line, age_days)
    text = line.strip
    age_suffix = age_days ? " (age: #{age_days}d)" : ""
    "#{text}#{age_suffix}"
  end
end

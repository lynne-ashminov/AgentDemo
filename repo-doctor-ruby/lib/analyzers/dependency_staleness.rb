require_relative "base"

class DependencyStalenessAnalyzer < BaseAnalyzer
  # Minimum version considered "fresh" for a few well-known gems. Anything
  # pinned below these is flagged as stale.
  MIN_VERSIONS = {
    "rails" => "7.0",
    "nokogiri" => "1.14",
    "puma" => "6.0",
    "pg" => "1.4",
    "rack" => "3.0",
    "sidekiq" => "7.0",
    "devise" => "4.9"
  }.freeze

  # Gems that are abandoned or actively discouraged in modern Ruby projects.
  DEPRECATED_GEMS = %w[
    therubyracer
    paperclip
    rest-client
    httparty-cache
    activerecord-deprecated_finders
  ].freeze

  GEM_LINE_REGEX = /^\s*gem\s+['"]([^'"]+)['"](?:\s*,\s*(.+))?$/.freeze
  VERSION_REGEX = /['"]([^'"]+)['"]/.freeze

  def name = "dependency-staleness"
  def description = "Checks Gemfile for outdated or unpinned dependencies"

  def run(repo_path)
    gemfile = File.join(repo_path, "Gemfile")
    return result(findings: [], score: 100) unless File.file?(gemfile)

    gems = parse_gemfile(gemfile)
    return result(findings: [], score: 100) if gems.empty?

    findings = gems.flat_map { |gem| evaluate(gem, gemfile) }
    score = score_for(gems, findings)
    result(findings: findings, score: score)
  end

  private

  def parse_gemfile(path)
    File.foreach(path).with_index(1).each_with_object([]) do |(line, lineno), gems|
      next if line.strip.start_with?("#")
      match = line.match(GEM_LINE_REGEX)
      next unless match

      name = match[1]
      version = extract_version(match[2])
      gems << { name: name, version: version, line: lineno }
    end
  end

  def extract_version(args)
    return nil if args.nil? || args.strip.empty?

    # The version constraint, if present, is the first string literal in the args.
    version_match = args.match(VERSION_REGEX)
    return nil unless version_match

    constraint = version_match[1]
    # Skip things like `group: :test` — version strings always contain a digit.
    constraint.match?(/\d/) ? constraint : nil
  end

  def evaluate(gem, gemfile)
    findings = []

    if DEPRECATED_GEMS.include?(gem[:name])
      findings << finding(
        file: gemfile,
        line: gem[:line],
        severity: :error,
        message: "#{gem[:name]} is deprecated and should be replaced"
      )
    end

    if gem[:version].nil?
      findings << finding(
        file: gemfile,
        line: gem[:line],
        severity: :warning,
        message: "#{gem[:name]} has no version constraint"
      )
    elsif stale?(gem[:name], gem[:version])
      findings << finding(
        file: gemfile,
        line: gem[:line],
        severity: :warning,
        message: "#{gem[:name]} is pinned to old version #{gem[:version]} (minimum recommended: #{MIN_VERSIONS[gem[:name]]})"
      )
    end

    findings
  end

  def stale?(gem_name, constraint)
    minimum = MIN_VERSIONS[gem_name]
    return false unless minimum

    pinned = numeric_version(constraint)
    return false unless pinned

    compare_versions(pinned, minimum) < 0
  end

  def numeric_version(constraint)
    constraint[/\d+(?:\.\d+)*/]
  end

  def compare_versions(a, b)
    a_parts = a.split(".").map(&:to_i)
    b_parts = b.split(".").map(&:to_i)
    length = [a_parts.size, b_parts.size].max
    a_parts.fill(0, a_parts.size...length)
    b_parts.fill(0, b_parts.size...length)
    a_parts <=> b_parts
  end

  def score_for(gems, findings)
    flagged_gems = findings.map { |f| f.message.split(" ").first }.uniq
    healthy = gems.count - flagged_gems.count { |name| gems.any? { |g| g[:name] == name } }
    ((healthy.to_f / gems.count) * 100).round
  end
end

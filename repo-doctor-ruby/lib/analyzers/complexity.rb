require_relative "base"

class ComplexityAnalyzer < BaseAnalyzer
  FILE_LINES_WARN = 200
  FILE_LINES_ERROR = 500
  FILE_METHODS_WARN = 15
  FILE_METHODS_ERROR = 30
  METHOD_LINES_WARN = 30

  EXCLUDED_DIRS = %w[.git vendor node_modules .bundle tmp log].freeze

  def name = "complexity"
  def description = "Flags files and methods that exceed complexity thresholds"

  def run(repo_path)
    findings = []
    files = ruby_files(repo_path)
    bad_files = 0

    files.each do |path|
      file_findings = analyze_file(path)
      findings.concat(file_findings)
      bad_files += 1 unless file_findings.empty?
    end

    score = files.empty? ? 100 : (((files.length - bad_files).to_f / files.length) * 100).round
    result(findings: findings, score: score)
  end

  private

  def analyze_file(path)
    lines = File.readlines(path)
    methods = method_ranges(lines)

    findings = []
    findings << file_length_finding(path, lines.length) if lines.length > FILE_LINES_WARN
    findings << method_count_finding(path, methods.length) if methods.length > FILE_METHODS_WARN
    findings.concat(long_method_findings(path, methods))
    findings
  end

  def file_length_finding(path, count)
    severity = count > FILE_LINES_ERROR ? :error : :warning
    finding(file: path, message: "file has #{count} lines (threshold: #{FILE_LINES_WARN})", severity: severity)
  end

  def method_count_finding(path, count)
    severity = count > FILE_METHODS_ERROR ? :error : :warning
    finding(file: path, message: "file has #{count} methods (threshold: #{FILE_METHODS_WARN})", severity: severity)
  end

  def long_method_findings(path, methods)
    methods.filter_map do |name, start_line, length|
      next unless length > METHOD_LINES_WARN
      finding(
        file: path,
        message: "method '#{name}' is #{length} lines (threshold: #{METHOD_LINES_WARN})",
        severity: :warning,
        line: start_line
      )
    end
  end

  def ruby_files(repo_path)
    files = []
    walk(repo_path) { |path| files << path if path.end_with?(".rb") }
    files
  end

  def walk(dir, &block)
    Dir.children(dir).each do |entry|
      next if EXCLUDED_DIRS.include?(entry)
      next if entry.start_with?(".") && entry != "."
      full_path = File.join(dir, entry)
      if File.directory?(full_path)
        walk(full_path, &block)
      else
        yield full_path
      end
    end
  rescue Errno::ENOENT, Errno::EACCES
    # Ignore directories we can't read.
  end

  # Returns [[name, start_line (1-indexed), length_in_lines], ...]
  # Tracks nesting via `def`/`end` and uses keyword position to avoid
  # matching `end` inside strings or trailing `def foo = ...` endless defs.
  def method_ranges(lines)
    methods = []
    stack = []
    depth = 0

    lines.each_with_index do |raw, idx|
      line = raw.rstrip
      stripped = line.sub(/^\s*/, "")

      if (m = stripped.match(/\Adef\s+(self\.)?([A-Za-z_][\w!?=]*)/))
        # Endless method: `def foo = expr` — single line, no `end`.
        if stripped.match?(/\Adef\s+(self\.)?[A-Za-z_][\w!?=]*[^\n]*=\s*[^=]/) && !stripped.match?(/\Adef\s.*\bdo\b/)
          methods << [m[2], idx + 1, 1] if depth == stack.length # endless def at any depth
        else
          stack << { name: m[2], start: idx + 1, depth: depth }
          depth += 1
        end
      elsif block_opener?(stripped)
        depth += 1
      elsif stripped == "end" || stripped.start_with?("end ") || stripped.start_with?("end\t")
        depth -= 1
        if !stack.empty? && stack.last[:depth] == depth
          opened = stack.pop
          methods << [opened[:name], opened[:start], (idx + 1) - opened[:start] + 1]
        end
      end
    end

    methods
  end

  # Lines that open a new `end`-terminated block (not method definitions).
  def block_opener?(stripped)
    return true if stripped.match?(/\A(class|module|if|unless|case|while|until|for|begin)\b/)
    return true if stripped.match?(/\bdo\s*(\|[^|]*\|)?\s*\z/)
    false
  end
end

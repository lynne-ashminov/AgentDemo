require_relative "base"

class SecurityScannerAnalyzer < BaseAnalyzer
  SKIP_DIRS = %w[.git node_modules vendor tmp log].freeze
  REQUIRED_GITIGNORE_PATTERNS = %w[.env *.pem *.key].freeze
  MAX_SCAN_BYTES = 1_000_000

  # Patterns for likely secrets. Each entry has a label and a regex.
  # The capture allows us to report the matched key/identifier.
  SECRET_PATTERNS = [
    { label: "AWS access key", regex: /\b(AKIA[0-9A-Z]{16})\b/ },
    { label: "AWS secret env var", regex: /\b(AWS_SECRET_ACCESS_KEY|AWS_ACCESS_KEY_ID)\s*[:=]/i },
    { label: "Generic secret", regex: /\b(SECRET_KEY(?:_BASE)?|SECRET_TOKEN|API_SECRET)\s*[:=]\s*\S+/i },
    { label: "Hardcoded password", regex: /\b(password|passwd|pwd)\s*[:=]\s*["'][^"'\s]{6,}["']/i },
    { label: "API token", regex: /\b(api[_-]?key|api[_-]?token|access[_-]?token|auth[_-]?token)\s*[:=]\s*["'][^"'\s]{8,}["']/i },
    { label: "Database URL", regex: /\b(DATABASE_URL|DB_URL)\s*[:=]/i },
    { label: "Private key block", regex: /-----BEGIN\s+(?:RSA|DSA|EC|OPENSSH|PRIVATE)\s+PRIVATE KEY-----/ }
  ].freeze

  def name = "security-scanner"
  def description = "Scans for hardcoded secrets and missing .gitignore rules"

  def run(repo_path)
    findings = []
    findings.concat(scan_gitignore(repo_path))
    findings.concat(scan_files(repo_path))

    errors = findings.count { |f| f.severity == :error }
    warnings = findings.count { |f| f.severity == :warning }
    score = 100 - (errors * 20) - (warnings * 5)

    result(findings: findings, score: score)
  end

  private

  def scan_gitignore(repo_path)
    findings = []
    gitignore_path = File.join(repo_path, ".gitignore")

    unless File.file?(gitignore_path)
      findings << finding(
        file: repo_path,
        message: ".gitignore is missing — sensitive files may be committed",
        severity: :warning
      )
      return findings
    end

    contents = safe_read(gitignore_path).to_s
    lines = contents.lines.map(&:strip)
    REQUIRED_GITIGNORE_PATTERNS.each do |pattern|
      unless lines.include?(pattern)
        findings << finding(
          file: gitignore_path,
          message: ".gitignore does not include sensitive pattern '#{pattern}'",
          severity: :warning
        )
      end
    end
    findings
  end

  def scan_files(repo_path)
    findings = []
    walk(repo_path) do |path|
      relative = path.sub(/\A#{Regexp.escape(repo_path)}\/?/, "")
      basename = File.basename(path)

      # Committed .env files are themselves a finding, regardless of contents.
      if env_file?(basename)
        findings << finding(
          file: path,
          message: "#{relative} is committed and likely contains secrets",
          severity: :error
        )
      end

      next if binary?(path)
      next if File.size(path) > MAX_SCAN_BYTES

      scan_contents(path).each { |f| findings << f }
    end
    findings
  end

  def scan_contents(path)
    findings = []
    File.foreach(path).with_index(1) do |line, lineno|
      SECRET_PATTERNS.each do |pattern|
        next unless line =~ pattern[:regex]
        findings << finding(
          file: path,
          message: "Possible #{pattern[:label]} detected",
          severity: :error,
          line: lineno
        )
      end
    end
    findings
  rescue ArgumentError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
    # Non-UTF8 content slipped past the binary check; skip it.
    []
  end

  def walk(dir, &block)
    Dir.children(dir).each do |entry|
      next if SKIP_DIRS.include?(entry)
      full_path = File.join(dir, entry)
      if File.directory?(full_path)
        walk(full_path, &block)
      elsif File.file?(full_path)
        yield full_path
      end
    end
  rescue Errno::ENOENT, Errno::EACCES
    # Directory disappeared or is unreadable; skip silently.
  end

  def env_file?(basename)
    basename == ".env" || basename.start_with?(".env.")
  end

  # Treat a file as binary if its first chunk contains a null byte. This is
  # the same heuristic git uses and is good enough to skip images/archives.
  def binary?(path)
    chunk = File.open(path, "rb") { |f| f.read(8192) }
    return false if chunk.nil? || chunk.empty?
    chunk.include?("\x00")
  rescue Errno::ENOENT, Errno::EACCES
    true
  end

  def safe_read(path)
    File.read(path, encoding: "UTF-8")
  rescue Errno::ENOENT, Errno::EACCES
    nil
  end
end

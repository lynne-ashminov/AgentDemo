require_relative "base"

class DocHealthAnalyzer < BaseAnalyzer
  CONFLICT_MARKERS = ["<<<<<<<", "=======", ">>>>>>>"].freeze
  LINK_REGEX = /\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)/

  def name = "doc-health"
  def description = "Checks README and markdown link health"

  def run(repo_path)
    findings = []

    readme = find_readme(repo_path)
    if readme.nil?
      findings << finding(file: repo_path, message: "README.md is missing", severity: :error)
    else
      findings.concat(check_links(repo_path, readme))
    end

    markdown_files(repo_path).each do |md_path|
      findings.concat(check_conflict_markers(md_path))
    end

    score = 100 - penalty(findings)
    result(findings: findings, score: score)
  end

  private

  def find_readme(repo_path)
    candidate = File.join(repo_path, "README.md")
    File.file?(candidate) ? candidate : nil
  end

  def markdown_files(repo_path)
    Dir.glob(File.join(repo_path, "**", "*.md")).reject do |path|
      rel = path.sub("#{repo_path}/", "")
      rel.start_with?(".git/", "node_modules/", "vendor/")
    end
  end

  def check_links(repo_path, readme_path)
    findings = []
    File.foreach(readme_path).with_index(1) do |line, lineno|
      line.scan(LINK_REGEX).each do |match|
        target = match.first
        next if external?(target)
        next if anchor_only?(target)
        path = resolve(repo_path, readme_path, target)
        next if File.exist?(path)

        findings << finding(
          file: readme_path,
          line: lineno,
          message: "Broken link: #{target}",
          severity: :warning
        )
      end
    end
    findings
  end

  def external?(target)
    target.start_with?("http://", "https://", "mailto:")
  end

  def anchor_only?(target)
    target.start_with?("#")
  end

  def resolve(repo_path, source_file, target)
    cleaned = target.split("#", 2).first.to_s
    base_dir = File.dirname(source_file)
    File.expand_path(cleaned, base_dir)
  end

  def check_conflict_markers(md_path)
    findings = []
    File.foreach(md_path).with_index(1) do |line, lineno|
      CONFLICT_MARKERS.each do |marker|
        if line.start_with?(marker)
          findings << finding(
            file: md_path,
            line: lineno,
            message: "Merge conflict marker (#{marker}) found",
            severity: :error
          )
          break
        end
      end
    end
    findings
  end

  def penalty(findings)
    findings.sum do |f|
      case f.severity
      when :error then 25
      when :warning then 10
      else 2
      end
    end
  end
end

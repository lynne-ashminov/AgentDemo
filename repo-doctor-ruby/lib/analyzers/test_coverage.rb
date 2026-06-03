require_relative "base"

class TestCoverageAnalyzer < BaseAnalyzer
  def name = "test-coverage"
  def description = "Checks for spec files matching lib files by naming convention"

  def run(repo_path)
    lib_dir = File.join(repo_path, "lib")
    spec_dir = File.join(repo_path, "spec")

    return result(findings: [], score: 100) unless File.directory?(lib_dir)

    lib_files = ruby_files_under(lib_dir)
    return result(findings: [], score: 100) if lib_files.empty?

    unless File.directory?(spec_dir)
      findings = [finding(file: repo_path, message: "No spec/ directory found", severity: :error)]
      return result(findings: findings, score: 0)
    end

    uncovered = lib_files.reject { |lib_file| spec_exists?(repo_path, lib_file) }

    findings = uncovered.map do |lib_file|
      relative = lib_file.sub("#{repo_path}/", "")
      expected = expected_spec_path(repo_path, lib_file).sub("#{repo_path}/", "")
      finding(file: relative, message: "No spec found for #{relative} (expected #{expected})", severity: :warning)
    end

    covered = lib_files.size - uncovered.size
    score = (covered.to_f / lib_files.size * 100).round
    result(findings: findings, score: score)
  end

  private

  def ruby_files_under(dir)
    Dir.glob(File.join(dir, "**", "*.rb"))
  end

  def expected_spec_path(repo_path, lib_file)
    relative = lib_file.sub("#{File.join(repo_path, "lib")}/", "")
    spec_relative = relative.sub(/\.rb\z/, "_spec.rb")
    File.join(repo_path, "spec", spec_relative)
  end

  def spec_exists?(repo_path, lib_file)
    File.exist?(expected_spec_path(repo_path, lib_file))
  end
end

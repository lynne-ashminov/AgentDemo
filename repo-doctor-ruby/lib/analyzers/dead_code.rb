require "set"
require_relative "base"

class DeadCodeAnalyzer < BaseAnalyzer
  def name = "dead-code"
  def description = "Detects .rb files never required by any other file"

  def run(repo_path)
    lib_dir = File.join(repo_path, "lib")
    return result(findings: [], score: 100) unless File.directory?(lib_dir)

    lib_files = ruby_files(lib_dir)
    return result(findings: [], score: 100) if lib_files.empty?

    referenced = referenced_files(repo_path, lib_files)
    entry_points = entry_point_files(repo_path, lib_files)
    live = referenced | entry_points

    dead = lib_files - live
    findings = dead.map do |path|
      finding(
        file: path,
        message: "File is never required by any other file",
        severity: :warning
      )
    end

    score = ((live.size.to_f / lib_files.size) * 100).round
    result(findings: findings, score: score)
  end

  private

  def ruby_files(dir)
    Dir.glob(File.join(dir, "**", "*.rb")).map { |p| File.expand_path(p) }.sort
  end

  # Scan every .rb file in the repo for `require_relative` statements and
  # resolve them to absolute paths within lib_files.
  def referenced_files(repo_path, lib_files)
    lib_set = lib_files.to_set
    referenced = []

    source_files = Dir.glob(File.join(repo_path, "**", "*.rb"))
                      .map { |p| File.expand_path(p) }
                      .reject do |path|
      path.include?("/.git/") || path.include?("/vendor/") || path.include?("/node_modules/")
    end

    source_files.each do |source|
      File.foreach(source) do |line|
        match = line.match(/require_relative\s+["']([^"']+)["']/)
        next unless match

        target = resolve_require_relative(source, match[1])
        referenced << target if lib_set.include?(target)
      end
    rescue ArgumentError
      # skip files with invalid encoding
      next
    end

    referenced.uniq
  end

  def resolve_require_relative(source_file, relative_path)
    base = File.expand_path(File.dirname(source_file))
    target = File.expand_path(relative_path, base)
    target.end_with?(".rb") ? target : "#{target}.rb"
  end

  # Entry points: any lib file referenced from bin/, any lib file containing
  # `if __FILE__ == $0`, or a top-level lib/main.rb by convention.
  def entry_point_files(repo_path, lib_files)
    entry_points = []
    bin_dir = File.join(repo_path, "bin")

    if File.directory?(bin_dir)
      lib_set = lib_files.to_set
      bin_scripts = Dir.glob(File.join(bin_dir, "**", "*"))
                       .select { |p| File.file?(p) }
                       .map { |p| File.expand_path(p) }
      bin_scripts.each do |script|
        File.foreach(script) do |line|
          match = line.match(/require_relative\s+["']([^"']+)["']/)
          next unless match

          target = resolve_require_relative(script, match[1])
          entry_points << target if lib_set.include?(target)
        end
      rescue ArgumentError
        next
      end
    end

    lib_files.each do |path|
      entry_points << path if entry_point_by_convention?(path)
      contents = File.read(path)
      entry_points << path if contents.include?("__FILE__ == $0") || contents.include?("__FILE__ == $PROGRAM_NAME")
    rescue ArgumentError
      next
    end

    entry_points.uniq
  end

  # main.rb at the top of lib/ is treated as an entry point by convention,
  # mirroring the role of a bin/ script when no bin/ directory exists.
  def entry_point_by_convention?(path)
    File.basename(path) == "main.rb"
  end
end

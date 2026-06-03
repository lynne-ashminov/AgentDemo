require "time"
require_relative "../types"

class ReportRenderer
  TEMPLATE_PATH = File.join(__dir__, "template.html")

  GRADE_THRESHOLDS = { 90 => ["A", "grade-a"], 80 => ["B", "grade-b"], 70 => ["C", "grade-c"], 60 => ["D", "grade-d"] }.freeze

  def self.render(results)
    template = File.read(TEMPLATE_PATH)

    if results.empty?
      return template
        .sub("{{TITLE}}", "Repo Doctor Report")
        .sub("{{OVERALL_SCORE}}", "N/A")
        .sub("{{ANALYZERS}}", "<p>No analyzers ran</p>")
        .sub("{{TIMESTAMP}}", Time.now.iso8601)
    end

    overall = (results.sum(&:score).to_f / results.length).round
    letter, css = grade_for(overall)

    template
      .sub("{{TITLE}}", "Repo Doctor Report")
      .sub("{{OVERALL_SCORE}}", "<span class=\"#{css}\">#{letter} (#{overall})</span>")
      .sub("{{ANALYZERS}}", results.map { |r| render_analyzer(r) }.join("\n"))
      .sub("{{TIMESTAMP}}", Time.now.iso8601)
  end

  def self.grade_for(score)
    GRADE_THRESHOLDS.each { |threshold, val| return val if score >= threshold }
    ["F", "grade-f"]
  end

  def self.render_analyzer(result)
    letter, css = grade_for(result.score)
    findings_html = if result.findings.empty?
      '<p class="no-findings">No issues found</p>'
    else
      items = result.findings.map do |f|
        line_str = f.line ? ":#{f.line}" : ""
        "<li><span class=\"severity #{f.severity}\">#{f.severity}</span>" \
        "<span class=\"file\">#{f.file}#{line_str}</span>" \
        "<span class=\"message\">#{f.message}</span></li>"
      end.join
      "<ul class=\"findings\">#{items}</ul>"
    end

    <<~HTML
      <section class="analyzer">
        <div class="analyzer-header" onclick="this.parentElement.classList.toggle('expanded')">
          <span class="analyzer-name">#{result.analyzer}</span>
          <span class="score #{css}">#{letter} (#{result.score})</span>
        </div>
        <div class="analyzer-body">#{findings_html}</div>
      </section>
    HTML
  end

  private_class_method :grade_for, :render_analyzer
end

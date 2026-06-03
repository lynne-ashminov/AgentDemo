# Repo Doctor Analyzers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the 8 analyzers defined in `EPIC.md` via parallel Claude Code subagents in isolated git worktrees, each opening a PR with all tests green.

**Architecture:** The main session does orchestration only. Each of the 8 analyzers is built by a single fresh subagent inside its own worktree. Each subagent follows TDD (write failing spec → implement → green) and opens a PR when done. Analyzers are completely independent — they share no code beyond `BaseAnalyzer`.

**Tech Stack:** Ruby (rbenv-managed), RSpec, Bundler, `Open3` for shell-out, git worktrees, GitHub CLI (`gh`).

---

## Prerequisites (Main Session)

### Task 0: Verify baseline environment

The repo has no `.ruby-version` file, but `Gemfile.lock` was generated under ruby 3.x. rbenv on this machine has 3.2.5+ available. Gems are not currently installed.

**Files:**
- Read: `Gemfile`, `Gemfile.lock`

- [ ] **Step 0.1: Confirm a working ruby is selected**

Run:
```bash
ruby --version
```
Expected: a 3.x version. If `ruby --version` reports a version not installed by rbenv (look for `rbenv: command not found` style errors), tell the user — do NOT silently create a `.ruby-version` file (this modifies the working tree). Ask the user which ruby they want pinned.

- [ ] **Step 0.2: Install gems**

Run:
```bash
bundle install
```
Expected: "Bundle complete!" with no errors.

- [ ] **Step 0.3: Confirm baseline test suite is green**

Run:
```bash
bundle exec rspec
```
Expected: all existing specs pass (`cli_spec.rb`, `types_spec.rb`, anything under `spec/analyzers/`, anything under `spec/renderer/`). Record the count. This is the baseline — every analyzer agent must keep this green and add to it.

- [ ] **Step 0.4: Confirm gh CLI is authenticated**

Run:
```bash
gh auth status
```
Expected: "Logged in to github.com". If not, surface to the user — agents cannot open PRs without it.

---

## Orchestration (Main Session)

### Task 1: Dispatch all 8 analyzer agents in parallel

**Files:** none modified in the main session — work happens in worktrees.

- [ ] **Step 1.1: Send a single message containing 8 parallel `Agent` calls**

For each of the 8 analyzers below, dispatch one `Agent` call with:
- `subagent_type: "general-purpose"`
- `isolation: "worktree"`
- `run_in_background: true`
- `description`: `"Implement <analyzer-name> analyzer"`
- `prompt`: the canonical per-agent prompt template (see Appendix A) with the analyzer-specific fields filled in (see Appendix B for the table).

All 8 `Agent` calls go in **one message** so they run concurrently. Do not dispatch them serially.

- [ ] **Step 1.2: Wait for completion notifications**

Each agent runs autonomously to PR open. Do not poll. The harness will notify on each completion.

- [ ] **Step 1.3: Collect PR URLs and report to user**

As each agent finishes, capture its PR URL from the tool result and surface it to the user. After all 8 finish, post a summary listing all 8 PR URLs and any failures.

- [ ] **Step 1.4: Handle failures**

If an agent fails (didn't open a PR, tests didn't pass, hit an error it couldn't resolve), do NOT silently re-dispatch. Surface the failure to the user with the agent's final message and ask how to proceed.

---

## Appendix A — Canonical Per-Agent Prompt Template

When dispatching each analyzer agent, use this prompt verbatim, replacing the four `<<...>>` placeholders. Every other instruction stays identical across all 8 agents so behaviour is uniform.

```
You are implementing ONE analyzer for the Repo Doctor CLI tool. You are working
in an isolated git worktree off `main`. Your job ends when you have a green
test suite and an open PR.

## Your assignment

- Analyzer name (kebab-case): <<ANALYZER_NAME>>
- File to create: <<ANALYZER_FILE>>
- Spec file to create: <<SPEC_FILE>>
- Class name: <<CLASS_NAME>>
- EPIC.md section to read: section "<<ANALYZER_NAME>>" in EPIC.md

## Required reading (in order)

1. `CLAUDE.md` — project conventions, file naming, the `--analyzer` flag
2. The EPIC.md section for your assigned analyzer — this is your spec; the
   "Acceptance Criteria" subsection is the contract you must satisfy
3. `lib/analyzers/base.rb` — the base class you extend
4. `lib/analyzers/file_count.rb` — reference analyzer; match its shape
5. `lib/types.rb` — `Finding` and `AnalyzerResult` structs
6. `test-fixtures/unhealthy-repo-ruby/` — the fixture your spec runs against;
   inspect its contents so your spec asserts against what's actually there

## Workflow (TDD, strict)

1. Create a new branch in this worktree:
   `git checkout -b feat/<<ANALYZER_NAME>>-analyzer`
2. Write your spec at <<SPEC_FILE>> covering ALL acceptance criteria for your
   analyzer. Assert against the fixture repo at
   `test-fixtures/unhealthy-repo-ruby/`. Score assertions MUST use ranges
   (e.g. `expect(result.score).to be < 100`) not exact values.
3. Run `bundle exec rspec <<SPEC_FILE>>` and confirm specs fail for the right
   reason (class not defined / not yet implemented). Capture this in your
   working notes.
4. Implement <<ANALYZER_FILE>> as a class <<CLASS_NAME>> extending
   `BaseAnalyzer`. Use only Ruby stdlib and `Open3` (the latter only if you
   shell out to git). NO external gems. Do not modify `Gemfile`.
5. Run `bundle exec rspec <<SPEC_FILE>>` until green.
6. Run the FULL suite: `bundle exec rspec`. ALL specs must pass — yours and
   everyone else's. If a pre-existing spec fails, stop and report; do not
   modify pre-existing specs.
7. Smoke test against the unhealthy fixture:
   `bundle exec bin/repo-doctor test-fixtures/unhealthy-repo-ruby/ --analyzer <<ANALYZER_NAME>>`
   Verify the output matches your EPIC acceptance criteria (right findings,
   score in the expected range).
8. Smoke test against this very repo as a "healthy" sanity check:
   `bundle exec bin/repo-doctor . --analyzer <<ANALYZER_NAME>>`
   Note the score. It need not be 100, but it should be sensible.

## Quality bar (non-negotiable)

- Tests must pass before PR. Full `bundle exec rspec` green.
- Match the shape, naming, and style of `file_count.rb`. No clever divergence.
- Small, focused methods. No dead code, no commented-out scratch, no debug puts.
- Comments only where the WHY is non-obvious. No comments restating what
  well-named code already says.
- No premature abstraction. Do NOT extract shared helpers, modules, or
  refactor `BaseAnalyzer`. If you feel the urge, resist — that's a follow-up.
- Graceful degradation per your EPIC acceptance criteria (missing Gemfile,
  missing lib/, not a git repo, etc.).
- Score clamped to 0..100.

## Forbidden modifications

You MUST NOT modify any of these files. They are shared and would cause
conflicts across the 8 parallel agents:

- `lib/cli.rb`
- `lib/types.rb`
- `lib/analyzers/base.rb`
- `lib/analyzers/file_count.rb`
- `lib/renderer/*`
- `bin/repo-doctor`
- `Gemfile`, `Gemfile.lock`
- Any other analyzer's files in `lib/analyzers/` or `spec/analyzers/`

You ONLY create:

- <<ANALYZER_FILE>>
- <<SPEC_FILE>>

If you genuinely believe a shared file needs changing, STOP and report it
back instead of editing it.

## Commit & PR

Use conventional commits. Keep history clean — squash WIP commits before
opening the PR, or commit only when each step is green.

When tests are green and smoke tests look correct:

1. `git add <<ANALYZER_FILE>> <<SPEC_FILE>>`
2. `git commit -m "feat(<<ANALYZER_NAME>>): implement <<ANALYZER_NAME>> analyzer"`
3. `git push -u origin feat/<<ANALYZER_NAME>>-analyzer`
4. Open the PR with `gh pr create`. Title:
   `feat(<<ANALYZER_NAME>>): implement <<ANALYZER_NAME>> analyzer`.
   Body must include:
   - One-sentence summary
   - Link/reference to the relevant section of EPIC.md
   - Confirmed-green output of `bundle exec rspec` (last few lines)
   - Confirmed-good output of the smoke test against the unhealthy fixture
   - A test plan checklist

## Reporting back

Your final message back to the orchestrator MUST include:

- The PR URL
- The score the analyzer produced against the unhealthy fixture
- The score the analyzer produced against this repo
- Anything surprising or out-of-spec you encountered

If you could not finish (tests failing you can't fix, ambiguous acceptance
criterion, blocked on a shared file), say so plainly with what you tried.
Do NOT open a PR with a red test suite.
```

---

## Appendix B — Per-Agent Placeholder Values

Fill these into the prompt template above. **Class name must be the camelized
filename + `Analyzer`** per the `CLAUDE.md` convention.

| ANALYZER_NAME | ANALYZER_FILE | SPEC_FILE | CLASS_NAME |
| --- | --- | --- | --- |
| `dependency-staleness` | `lib/analyzers/dependency_staleness.rb` | `spec/analyzers/dependency_staleness_spec.rb` | `DependencyStalenessAnalyzer` |
| `dead-code` | `lib/analyzers/dead_code.rb` | `spec/analyzers/dead_code_spec.rb` | `DeadCodeAnalyzer` |
| `todo-debt` | `lib/analyzers/todo_debt.rb` | `spec/analyzers/todo_debt_spec.rb` | `TodoDebtAnalyzer` |
| `test-coverage` | `lib/analyzers/test_coverage.rb` | `spec/analyzers/test_coverage_spec.rb` | `TestCoverageAnalyzer` |
| `doc-health` | `lib/analyzers/doc_health.rb` | `spec/analyzers/doc_health_spec.rb` | `DocHealthAnalyzer` |
| `security-scanner` | `lib/analyzers/security_scanner.rb` | `spec/analyzers/security_scanner_spec.rb` | `SecurityScannerAnalyzer` |
| `complexity` | `lib/analyzers/complexity.rb` | `spec/analyzers/complexity_spec.rb` | `ComplexityAnalyzer` |
| `git-health` | `lib/analyzers/git_health.rb` | `spec/analyzers/git_health_spec.rb` | `GitHealthAnalyzer` |

---

## Appendix C — Definition of Done

- 8 PRs are open against `main`.
- Each PR's branch passes `bundle exec rspec` locally before push (verified by the agent in step 6 of its workflow).
- Each PR adds exactly two files: `lib/analyzers/<name>.rb` and `spec/analyzers/<name>_spec.rb`. No PR touches shared files (Task 1 surfaces violations).
- Running `bundle exec bin/repo-doctor test-fixtures/unhealthy-repo-ruby/` on `main` after all 8 PRs are merged produces a report with findings from all 8 analyzers and scores matching their EPIC acceptance criteria. (This verification is performed by the user post-merge, not by an agent.)

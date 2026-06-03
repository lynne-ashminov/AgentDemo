# Repo Doctor Analyzers — Parallel Execution Design

**Date:** 2026-06-03
**Scope:** Execution strategy for implementing the 8 analyzers defined in `EPIC.md`.
**Status:** Approved

## Context

`EPIC.md` is the analyzer-level spec. It defines 8 independent analyzers (dependency-staleness, dead-code, todo-debt, test-coverage, doc-health, security-scanner, complexity, git-health), each with acceptance criteria, file paths, class names, and code skeletons. The CLI scaffolding (`lib/cli.rb`, `lib/analyzers/base.rb`, `lib/renderer/`, `bin/repo-doctor`) and one reference analyzer (`lib/analyzers/file_count.rb`) already exist.

This document covers **how we build the 8 analyzers**, not what they do. For analyzer-level requirements, see `EPIC.md`.

## Strategy

Eight parallel Claude Code subagents, one per analyzer, each working in its own git worktree on its own branch. Each agent runs end-to-end: implement, test, push branch, open PR.

This works cleanly because every analyzer lives in its own file pair (`lib/analyzers/<name>.rb` + `spec/analyzers/<name>_spec.rb`) and the CLI auto-discovers analyzers at runtime — there is no central registration to coordinate.

## Per-Agent Workflow

Identical for all 8 agents. Each agent receives a self-contained prompt naming its analyzer and pointing at the relevant `EPIC.md` section.

1. **Isolation.** Branch off `main` in a dedicated worktree (e.g. `worktrees/analyzer-<name>` on branch `feat/<name>-analyzer`). Use the `isolation: "worktree"` parameter on dispatch.
2. **Orient.** Read `CLAUDE.md`, the assigned `EPIC.md` section, and `lib/analyzers/file_count.rb` as a reference pattern.
3. **Test-first.** Write `spec/analyzers/<name>_spec.rb` against `test-fixtures/unhealthy-repo-ruby/`, exercising all acceptance criteria. Verify specs fail before implementing.
4. **Implement.** Build `lib/analyzers/<name>.rb` extending `BaseAnalyzer`. Ruby stdlib + `Open3` only. No external gems.
5. **Verify.** `bundle exec rspec` must pass cleanly (full suite, not just the new spec). Run `bundle exec bin/repo-doctor test-fixtures/unhealthy-repo-ruby/ --analyzer <name>` as a smoke check.
6. **Commit & PR.** Conventional commit message. Push branch. Open PR with a summary linking to the `EPIC.md` section.

## Quality Bar

These apply to every analyzer agent:

- **Tests must pass before PR.** No exceptions. The agent must run `bundle exec rspec` and confirm a clean run before pushing.
- **Match the existing style.** Mirror `file_count.rb` for shape, naming, and convention. No clever divergence from established patterns.
- **Clean and maintainable.** Small, focused methods. No dead code. No commented-out scratch. No comments explaining what well-named code already says. Comments only where the *why* is non-obvious.
- **No premature abstraction.** Each analyzer is self-contained — don't extract shared helpers across analyzers (that's a follow-up if patterns emerge).
- **No external dependencies.** Ruby stdlib + `Open3` only, per `CLAUDE.md`.
- **Graceful degradation.** Each analyzer must handle missing inputs (no Gemfile, no `lib/`, not a git repo) without crashing — per acceptance criteria in `EPIC.md`.
- **Score must be 0–100, clamped.** Verified by spec.
- **Specs must use score ranges, not exact values** (per `EPIC.md` testing criteria).

## Orchestration

The main session dispatches all 8 agents in a single message (parallel `Agent` tool calls with `isolation: "worktree"` and full autonomy). It then waits on completions and, as each finishes, surfaces the PR URL to the user.

The main session does **not**:
- Merge PRs (user decides).
- Delete worktrees that still have uncommitted state.
- Touch shared files (`lib/cli.rb`, `lib/types.rb`, `lib/analyzers/base.rb`, `lib/renderer/*`). Any shared-file change indicates a problem and needs human review.

## Risks & Mitigations

| Risk | Mitigation |
| --- | --- |
| Auto-mode hides issues until completion | Per-agent quality bar above; PR is the review gate |
| All 8 agents read the same fixture | Read-only access — safe |
| PRs land in arbitrary order | Each PR touches disjoint files — no rebase needed |
| Agent picks an external gem to make life easier | Explicit instruction: stdlib + Open3 only |
| Agent commits without running tests | Explicit instruction + verification step in prompt |

## Out of Scope

- Merging the PRs (user-driven).
- New analyzers beyond the 8 in `EPIC.md`.
- Changes to the CLI, renderer, or `BaseAnalyzer`.
- Refactoring `file_count.rb` or other shared code.

## Success Criteria

- 8 PRs open, one per analyzer.
- Each PR has a green `bundle exec rspec` run locally before push.
- Each PR's analyzer runs cleanly via `bundle exec bin/repo-doctor test-fixtures/unhealthy-repo-ruby/ --analyzer <name>` and produces findings matching the `EPIC.md` acceptance criteria.
- No PR modifies shared files.

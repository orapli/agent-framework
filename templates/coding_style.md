# Coding Style — Mandatory Layout and Syntax Rules

> STATUS: BOOTSTRAP TEMPLATE. The Explorer must propose, and the Architect must
> ratify, project-specific rules derived from `product-repo/` conventions once the
> target repository is cloned. Until then, the general rules below are binding.

## General (all languages)
1. **Match the surrounding code.** Existing naming, indentation, comment density,
   and idiom in the touched file override any rule in this document.
2. No dead code, no commented-out blocks, no TODO without a task id.
3. Comments state constraints the code cannot express — never narrate the next
   line, never address the reviewer.
4. One logical change per commit; commit message = imperative summary +
   `[task_{id}]` suffix.
5. No new dependencies without an explicit `Task` specification authorizing it.
6. Public-facing behavior changes require a matching test in the same branch.

## Formatting Authority
`tools/lint_check.sh` is the single formatting authority. If it exits 0, style is
formally satisfied; reviewers may still reject on naming, structure, and clarity.

## Error Handling
- Fail loudly at boundaries; never swallow exceptions to make tests pass.
- Error messages must include the failing input's identity, never its secrets.

## Security Baseline
- No secrets, tokens, or credentials in the source tree or test fixtures.
- All external input validated at the entry seam, not deep in the call chain.

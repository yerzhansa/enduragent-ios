# Enduragent for iPhone

## Code

- No comments. No `//`, `/* */`, `///`, `// MARK:`, or `// swiftlint:disable`. The only exception is the swift-tools-version header in `Package.swift`. If code needs a comment, rename, split, or restructure it.
- No workarounds. No band-aids, "for now", temporary fixes, `TODO`, `FIXME`, or `HACK`. Fix the root cause or stop and report why you cannot.
- No second way to do something that already has one. One transport, one state model, one localization path through `CatalogKey`, one credits flow. Extend the existing path or replace it in the same change.
- Delete before you add. Remove dead code, unused types, and stale fixtures in the same change that touches them. Prefer the smallest diff that solves the problem.
- Never silence a failure. No `try?`, and no catch that discards the error. Use `try` and handle or propagate the error. To ignore one failure on purpose, catch its type, as in `catch is CancellationError`. The only allowed `try?` is a probing decode on a `Decoder` container. No force unwraps, `try!`, `print`, or `fatalError` without a message. In tests use `try #require(...)`.
- Add no SwiftLint baseline, and no `excluded` path that hides a violation.

## Language

- Use the terms in `CONTEXT.md`.

## Git and pull requests

- Every task branches off the latest `origin/main`. Delete the branch after merge.
- In a stacked sequence, leave a parent branch until the pull request that depends on it is merged. Then retarget the child to `main`, merge it, and delete both branches.
- Format commits as Conventional Commits: `<type>(ios): <description>`.
- Open every PR you create as a draft.
- Mark a PR ready only after CI passes and, for UI changes, `verify-ios` has run on the final version.
- Fix Critical and required review findings in the pull request. File every other finding with the `ledger` skill.

## Done means proven

- For UI changes, run the `verify-ios` skill and look at the screen you changed.

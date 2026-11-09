# Enduragent for iPhone

Each rule names what enforces it. A rule enforced only by review is a judgment call.

| Rule | Enforced by |
| --- | --- |
| No comments, `TODO`, `FIXME`, `HACK` or `swiftlint:disable`. Rename, split or restructure instead. | SwiftLint `no_comments`, `todo`; check-source `lint-disable` |
| Never silence a failure. No `try?` except a probing decode on a `Decoder` container. To ignore one failure on purpose, catch its type, as in `catch is CancellationError`. No force unwraps, `try!`, `print`, or `fatalError` without a message. In tests use `try #require(...)`. | SwiftLint `optional_try`, `swallowed_error`, `force_unwrapping`, `force_try`, `no_print`, `fatal_error_message` |
| One way to do each thing: one transport, one state model, one localization path through `CatalogKey`, one credits flow. Extend or replace the existing path in the same change. | SwiftLint and check-source ownership rules, such as `one_session_factory`; review |
| Fix the root cause, with no workaround or "for now" fix. Prefer the smallest diff that solves the problem. Delete dead code, unused types and stale fixtures you touch. | Review |
| No SwiftLint baseline, and no `excluded` path that hides a violation. | Review |
| Use the terms in `CONTEXT.md`. | Review |
| Branch off the latest `origin/main`. Commit as `<type>(ios): <description>`. Open every PR as a draft. In a stack, keep a parent branch until its child merges. Delete the branch after merge. | Review |
| Start the review when the PR opens. Mark it ready after CI passes and, for UI changes, after `verify-ios` ran on the final version. Fix Critical and Required findings and file the rest with the `ledger` skill. | CI starts the screen tests; review |
| Every new or changed test passes the authoring gate in the `test-audit` skill. | Review |
| A change is done when the commands under Development in `README.md` pass. | CI runs the same targets |
| When the operator says to keep going, decide and continue. End the turn with `Done.` or the one step only they can take. | Stop hook `make turn-end` |

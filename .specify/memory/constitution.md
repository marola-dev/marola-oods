# marola-oods constitution

The rules every spec under `specs/` is checked against in its plan's "Constitution Check". They
are not new: each one points at the rule it restates, and the pointed-to rule wins on any
difference. A spec here is the input to a MIP (marola's design record, MIP-0063 §4.7 keeps
spec-kit as prior art, not as a replacement); it does not replace one.

## I. Org invariants (AGENTS.md, MIP-0070 §5.1)

1. **Cost and deployment safety.** Nothing provisions or deploys a paid cloud resource without a
   person's explicit confirmation. Creating a Supabase project, a GCS bucket or a proxy VM is a
   person's act, even on a free tier.
2. **No secrets in code.** Connection strings and keys reach CI as GitHub Actions secrets or
   Workload Identity Federation. `.env.example` holds placeholders only.
3. **The agent-ready gate.** An agent starts implementation only on an issue labelled
   `agent-ready`. A spec, plan or task list is design, not implementation.
4. **Three commit trailers.** `Tested:`, `Cost:`, `Co-Authored-By: Claude <noreply@anthropic.com>`.
5. **Phase discipline.** `docs/PHASES.md` in the umbrella. A cloud backend is Phase 2; a spec that
   needs one says so and names the exception it relies on.

## II. Repository boundaries (MIP-0070 §5.4)

- Code lives in marola-app (the `oods/` sbt module); this repo holds data, workflows that run the
  pinned app image (`marola-image`), and docs. This repo never builds Scala.
- No repo reads another's tree. A contract crosses repos as an image, a release asset, a branch
  or a database, never as a path into a sibling checkout.

## III. Scala discipline (marola-app `.claude/rules/scala.md`)

- Scala 3, Kyo, direct style. Pure logic carries no effect type; Kyo stays at the I/O boundary.
- One trait per pluggable capability; callers depend on the trait. Clock, transport and
  connection are injected with real defaults.
- Expected failures are enums matched exhaustively; any `Abort.catching` site lists the cases it
  expects before its catch-all.
- Anything persisted (an enum on disk or in a column) has an explicit `label`/`fromLabel`, never
  `toString` or `ordinal`.
- Test doubles are hand-written trait instances that record what they saw. No mocking library.
- Reproduce a bug with a failing test before fixing it. Assert exact values and exact failures.

## IV. Data honesty (MIP-0001, MIP-0056)

- The verdict is the agency's own. Nothing recomputes PRÓPRIA/IMPRÓPRIA from counts; a summary
  marola computes (a share of proper samples) is labelled as marola's, next to the agency's.
- Censored counts (`<20`) keep their number and a qualifier; they never become NULL.
- A run that fetches nothing new writes nothing. A failed run leaves the last good data in place.
- Unknown is not proper: an `unknown` sample never counts towards a proper share.

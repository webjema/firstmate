## Tests - few, critical, shipped behaviour only

Write a test only for a rule whose breakage would corrupt state, lose work, or break a contract another component depends on.
Everything else: do not write the test.
A test asserts what shipped code does when it runs: inputs to outputs, side effects, error paths, invariants.
Never assert on test code, docs, comments, source text, config text, or message wording.
Found such a test?
Delete it.
A bug fix adds one regression test only if the bug meets the same bar.
Prove it can fail once: break the guarded line.
Run the tests your change affects.
CI runs the full suite.
Project files may name what is critical there; they do not restate this rule.

# Documentation

- Start with the reader's question. Keep one canonical owner per topic; update or replace existing
  guidance when behavior changes and link to that owner elsewhere.
- Keep intent, usable procedures, and non-obvious constraints. Exact mechanics and test cases belong
  in executable owners. Omit task/review history, implementation inventories, and copied contracts.
  Add instructions only for recurring risks that cannot be enforced or discovered elsewhere.
- Add a page only for a distinct reader need. Remove repetition before splitting a page; splitting
  duplicated text across files does not make it useful. Preserve [product requirements](product/AGENTS.md).
- [CI size limits](../Scripts/documentation_policy.py) bound living guides, the landing page, and
  agent instructions. Records and legal notices are exempt. Passing the limit does not prove good
  writing; changing a limit is a policy change requiring a reason in the PR.

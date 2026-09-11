# Product documentation

Preserve intended product requirements even when brevity or links to implementation would
otherwise suffice.

- Keep explicit interaction, state-transition, failure, accessibility, and visual requirements,
  including dimensions, timing, ordering, and edge cases when they express deliberate product choices.
- Do not remove a requirement merely because code or tests implement it. The product contract must
  remain useful for deciding whether that implementation is correct.
- Describe observable outcomes and relevant constraints. Link to code for internal mechanics that
  do not define product behavior; omit task history and repeated rationale.
- A documentation cleanup must not silently relax or change product requirements. When the
  contract and the verified shipped behavior disagree, the contract may be corrected to match the
  implementation, but the PR must state the divergence and the chosen side so it is reviewed as a
  product decision rather than a wording fix.

# Product documentation

These documents specify intended product behavior. Within this directory, preserving precise
requirements takes precedence over the root documentation rule's preference for brevity and
linking to implementation.

- Keep explicit interaction, state-transition, failure, accessibility, and visual requirements,
  including dimensions, timing, ordering, and edge cases when they express deliberate product choices.
- Do not remove a requirement merely because code or tests implement it. The product contract must
  remain useful for deciding whether that implementation is correct.
- Describe observable outcomes and relevant constraints. Link to code for internal mechanics that
  do not define product behavior; omit task history and repeated rationale.
- A documentation cleanup must not silently relax or change product requirements. Preserve the
  existing contract unless a behavior change is explicitly requested.

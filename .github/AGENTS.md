# GitHub automation

CI verifies the integrated Rust app on Linux and Apple Silicon. The required macOS checks aggregate must fail if either platform fails. Keep action revisions pinned, provide read-only permissions for untrusted PR code, and scope release staging to verified Rune tags on main. Historical Swift releases use their own update channel.

Keep credentials out of untrusted pull-request code and logs. Unset `ACTIONS_ID_TOKEN_REQUEST_TOKEN` and `ACTIONS_ID_TOKEN_REQUEST_URL` before installing untrusted dependencies or running agents. Use the trusted reviewer configuration for privileged publication.

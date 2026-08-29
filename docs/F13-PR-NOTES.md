## Summary

Packages `pf-shell` from launcher commit `3fc6a8ebd71ebe7c2bf261908fcbfbd6e8df65ea`
as the selected persistent foreground owner and `pf-session-authorityd` from runtime commit
`2dc47fb6eb0750e5b4c23bca44250d3e6a3f4738` as an independently-lived, durable authority.
The unit names match F07 `CommandTemplates`: `pf-foreground@.service` and
`pf-shell-selected.service`.

This is the product-010 F13 authoring half only. Product-010 has no physical device while the
GE8300 campaign owns tsp-base, so this PR provides packaging, offline unit-graph analysis, and
fault-test definitions. It makes no on-device boot or fault-proof claim; that proof is deferred
to the device follow-up bead when the DUT becomes available.

## Test plan

- [x] Run `python3 tests/verify-f13-unit-graph.py` and compare its output byte-for-byte with `docs/F13-UNIT-GRAPH-ANALYSIS.txt` (before the explanatory footer).
- [x] Run `sh -n tests/f13-fault-definitions.sh` and `tests/f13-fault-definitions.sh --check`.
- [x] Run the repository shell regression tests and systemd offline unit verification.
- [ ] Run the deferred on-device boot/fault proof (deferred to the device follow-up bead; product-010 does not currently own a DUT).

## Related PRs

- https://github.com/pocketforge-os/launcher/pull/13
- https://github.com/pocketforge-os/runtime/pull/52

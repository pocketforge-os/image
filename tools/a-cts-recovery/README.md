# A-CTS recovery runner source

This directory owns the text sources for the temporary crash-continuing A-CTS
recovery kits used on PocketForge CTS images. It intentionally does not contain
an OS image, a CTS binary, compiled probes, a case list, or device receipts.

`a-cts-dut` is the device-side worker and `direct-boot.sh` is the laptop-side
orchestrator. The response helpers and host verifier are included because their
contracts define when volatile device evidence has actually been collected.
The source orchestrator requires `PF_ACTS_BEAD_ID` and `PF_ACTS_IMAGE`; a sealed
kit may bind those two values to its admitted bead and immutable raw image.

The sealed deployment kits live outside Git under the recovery receipt tree.
When changing these sources, copy the reviewed text files into each new kit,
run `test-worker-recovery.sh` and `test-worker-terminal.sh`, run the kit's full
hermetic suite and exact-rootfs smoke, and regenerate its strict `SHA256SUMS`
manifest. Device boots remain the coordinator's responsibility.

The r41 regression test models the important terminal protocol: an intermediate
`harness_stop` reason is progress while the supervisor is still building its
partial archive. Poll reports a terminal result only after the supervisor has
exited and the archive is ready; finalize waits with a bound and then collects.

The r42 regression test reenacts a reset whose first post-reset clear/readback
fails while EGL and the PowerVR-backed Zink context are available. Recovery
retains every bounded sanity attempt, resumes at the next case after a later
healthy draw, and stops with a verified partial result only after retry
exhaustion or the per-boot reset-case cap.

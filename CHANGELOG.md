# Changelog

## 0.2.0

- Add a native Qt Quick app with five guided screens, Portuguese/English, responsive layouts,
  live desktop accent/rounding, system file picker, visible-terminal privilege handoff and Arch packaging.
- Add readiness reports, ISO SHA-256 verification, saved-state reporting and installer guidance.
- Adopt relevant Hop workflow ideas with attribution and a documented feature comparison.
- Pin ISO fingerprints, GPT disk identity and Linux partition identity/geometry to each plan.
- Reject partition overlaps, unsupported sector sizes, undersized carriers and unsafe repeated phases.
- Back up both GPT ends, preserve interrupted-phase state and lock storage operations per plan.
- Account for LUKS payload overhead and resize the mapping between filesystem and partition shrink.
- Correct Linux staging dispatch/dry-run and installer BootNext selection.
- Preserve default boot priority, restore saved priority and support canceling BootNext.
- Verify the Linux carrier copy; support Windows `install.esd` alongside split WIM media.
- Add non-destructive regression coverage, recovery/security docs and the raccoon mascot.
- Clarify validation limits: generalized storage phases still need disposable-VM install tests.

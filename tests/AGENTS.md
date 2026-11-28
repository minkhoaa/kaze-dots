# Verification boundaries

## Gate 1: headless

- Run the [root static and unit commands](../AGENTS.md#local-verification) before deployment.
  Register new Lua suites in [run.lua](run.lua); placing a file under `integration/` does not execute it.
- Use a disposable home, XDG dirs and stubbed commands for compositor, package and service operations.
  Keep Lua tests independent of the operator's display, user bus and installed dotfiles.
- Test sampler classification and thresholds with [synthetic process data](vm/test_idle_sampler.py).
  A passing sampler unit test is not an idle measurement.

## Arch KVM: guest only

- Launch [the shell verifier](vm/verify-kaze-shell.sh) from the repository root, not from inside the guest.
  After Rust edits, rebuild with `(cd kaze-shell && cargo build --release --frozen)`; the verifier reuses an existing executable.
- Use [common.sh](vm/common.sh): `require_vm_off` before creating a disposable qcow2 CoW overlay with `make_overlay`.
  Boot **only** the overlay with its own EFI variables. Never boot, stage into, or commit changes to the backing image.
- Do not substitute [verify.sh](vm/verify.sh): it boots the supplied VM directory directly, without creating an overlay.
- Keep the [launcher's Intel iGPU pinning](../scripts/launch-vm.sh) for comparable 1920×1080 samples.
  On success, failure or interrupt, power off the guest and wait for its PID to exit before discarding the overlay.
- Let `wait_session` establish readiness. Run the [T0 sampler](vm/idle_sampler.py) on cold idle **before** interactive probes.
  Check PSS, CPU, context switches and early portals (processes **and** boot journal); never activate a portal to test for it.
- `--samples 0` skips the cold resource sample, not the functional checks. Don't report T0 budgets from that run.

## Blind verification

- Drive the guest through public inputs; observe pixels, process state and protocol results rather than adding test hooks to the product.
- Keep QMP input on the private overlay socket, never the host desktop. Keep interactive probes separate from the cold boot sample.
- For product fixes, use the reported case ID, redacted symptom and screenshots, not the private cases or oracles.
  Keep random tokens and harness paths out of reports. A missing selected case or required screenshot is a failure, not a skip.

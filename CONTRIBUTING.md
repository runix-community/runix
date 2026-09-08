# Contributing

Runix is experimental. Prefer small changes with a regression test over adding
new integrations without runtime coverage.

## Checks

- Run `nix fmt` and `nix flake check --print-build-logs`.
- The hardware example is evaluated on x86_64, not boot-tested by CI.
- `bash tests/activation.sh` tests managed-file updates without root or Nix.
- `nix build .#vm` followed by `python3 tests/vm-smoke.py ./result` runs the
  x86_64 boot, Nix daemon, repeated-activation, and offline-activation smoke test. It needs KVM and
  uses a temporary disk rather than the default guest image.
- Never run activation or installer scripts directly against your development host.
- Test boot and privileged changes only in a disposable VM with a separate disk.

Include reproduction steps, architecture, configuration, and relevant logs in
bug reports. Remove passwords, hashes, keys, and machine-specific identifiers.

Module file/state setup belongs in `runix.preparationScripts`, which runs both
offline and live. Keep kernel changes, networking, device operations, and process
control in `runix.activationScripts`, which is live-only. Offline preparation
must not require raw disks or a running service supervisor.

## Priorities

1. Automated UEFI/ext4 installation and reboot tests.
2. Failed and interrupted generation-switch tests with service readiness checks.
3. ZFS boot and desktop login/session tests.
4. Safe pruning of obsolete boot files and clearer generated option documentation.

"""Boot a disposable VM; never use the developer's existing guest disk."""

import os
import selectors
import subprocess
import sys
import tempfile
import time


with tempfile.TemporaryDirectory(prefix="runix-smoke-") as directory:
    environment = os.environ | {"RUNIX_VM_DISK": directory + "/guest.qcow2"}
    process = subprocess.Popen(
        [sys.argv[1]],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=environment,
    )
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    output = b""
    sent = False
    deadline = time.monotonic() + 120
    try:
        while time.monotonic() < deadline:
            for key, _ in selector.select(timeout=1):
                chunk = os.read(key.fd, 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
                output += chunk
            if not sent and b"bash-" in output and b"# " in output:
                command = (
                    "set -x; test \"$(stat -c %a /tmp)\" = 1777 && "
                    "mountpoint -q /dev/pts && mountpoint -q /dev/shm && "
                    "script -q -c true /dev/null && "
                    "sv -w 30 check /run/runit/service/nix-daemon && "
                    "nix store info --store daemon && "
                    "mkdir -p /etc/runix && touch /etc/runix/smoke-preserve && "
                    "/run/current-system/activate && "
                    "test -f /etc/runix/smoke-preserve && "
                    "target=$(mktemp -d /tmp/offline.XXXXXX) && "
                    "mkdir -p \"$target\"/{nix,run,dev,proc} && "
                    "mount --rbind /nix \"$target/nix\" && "
                    "mount --make-rslave \"$target/nix\" && "
                    "mount --bind /dev \"$target/dev\" && "
                    "mount --bind /proc \"$target/proc\" && "
                    "mount -t tmpfs tmpfs \"$target/run\" && "
                    "system=$(readlink -f /run/current-system) && "
                    "chroot \"$target\" \"$system/activate\" --offline && "
                    "test -f \"$target/etc/passwd\" && "
                    "test -f \"$target/etc/nix/nix.conf\" && "
                    "test -f \"$target/etc/ssl/certs/ca-certificates.crt\" && "
                    "test -f \"$target/etc/sysctl.d/60-runix.conf\" && "
                    "test -f \"$target/etc/locale.conf\" && "
                    "test -L \"$target/run/current-system\" && "
                    "test ! -e \"$target/run/runit/service\" && "
                    "test \"$(readlink -f /run/current-system)\" = \"$system\" && "
                    "sv -w 10 check /run/runit/service/nix-daemon && "
                    "umount -l \"$target/nix\" && "
                    "umount \"$target/dev\" && umount \"$target/proc\" && "
                    "umount \"$target/run\" && "
                    "rm -rf \"$target\" && "
                    "printf 'RUNIX_%s\\n' SMOKE_PASSED; poweroff\n"
                )
                process.stdin.write(command.encode())
                process.stdin.flush()
                sent = True
            if process.poll() is not None and not selector.get_map():
                break
        else:
            raise RuntimeError("VM smoke test timed out")
        if b"RUNIX_SMOKE_PASSED" not in output or process.returncode != 0:
            raise RuntimeError("VM smoke test failed")
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        selector.close()

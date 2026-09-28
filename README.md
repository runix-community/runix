# Runix

A NixOS that runs on Runit.
Docs are in progress.

# Warning
Just in case it isn't obvious, Runix is a very new project, so test it in a VM.

## Binary cache

CI-built Runix artifacts and patched desktop packages are available from the
public `runix-community` Cachix cache. Configure it in `flake.nix` with
`nixConfig`:

```nix
{
  nixConfig = {
    extra-substituters = [ "https://runix-community.cachix.org" ];
    extra-trusted-public-keys = [
      "runix-community.cachix.org-1:sENfG2mPWobsz1MKahUs+HOGfVt2L3OvG5oHHD5/coE="
    ];
  };

  # inputs and outputs...
}
```

Then allow the flake-provided cache configuration when building:

```sh
nix build --accept-flake-config .#vm
```

## Package channel

Runix includes [runixpkgs](https://github.com/runix-community/runixpkgs) by
default. Its packages are available as `pkgs.zwwm`, `pkgs.shojiwm` and
`pkgs.driftwm` in `runix.lib.runixSystem` modules. Add the window managers you
want to the system environment:

```nix
runix.lib.runixSystem {
  system = "x86_64-linux";
  modules = [
    ({ pkgs, ... }: {
      runix.packages = [ pkgs.zwwm pkgs.driftwm ];
    })
  ];
}
```

The same packages are available as `runix.packages.${system}.{zwwm,shojiwm,driftwm}`.
For a custom nixpkgs instance, use `runix.overlays.default`; the preconfigured
package set is also available through `runix.lib.mkPkgs system`. Upstream
sources and Nixpkgs revisions are pinned in the flake lock.

Window managers can also be enabled with `programs` options:

```nix
programs.zwwm.enable = true;
programs.shojiwm.enable = true;
programs.driftwm.enable = true;
```

Each has a `package` option, for example
`programs.zwwm.package = pkgs.zwwm.override { xwaylandSupport = false; };`.
When `runix.desktop.enable = true`, enabled Wayland sessions appear in SDDM.
To use only another compositor, set `programs.hyprland.enable = false`.

## Networking

`dhcpcd` is currently the recommended network configuration service:

```nix
runix.systemServices.dhcpcd.enable = true;
```

Do not enable `dhcpcd` and NetworkManager at the same time, as both services
would attempt to configure the same network interfaces.

# Credits
- [finix-project](https://github.com/finix-community/finix.git) provides very useful, helpful anti-systemd patches for some components.

## License

Runix is licensed under the BSD 3-Clause License. See [LICENSE](LICENSE).
Runit retains its upstream BSD-style license.

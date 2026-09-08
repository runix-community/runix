{
  description = "Runix, a runit-powered operating system built with Nix";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      mkPkgs =
        system:
        import nixpkgs {
          inherit system;
          overlays = [
            (import ./pkgs/libraries.nix)
            (final: prev: {
              procps = prev.procps.override { withSystemd = false; };
              linux-pam = prev.linux-pam.override { withLogind = false; }
                // { outputs = [ "out" ]; };
              util-linux = prev.util-linux.override {
                systemdSupport = false;
                pam = final.linux-pam;
              };
              util-linuxMinimal = prev.util-linuxMinimal.override {
                systemdSupport = false;
                pam = final.linux-pam;
              };
            })
            (import ./pkgs/services.nix)
            (import ./pkgs/desktop.nix)
            (import ./pkgs/qt.nix)
            (import ./pkgs/sddm.nix)
          ];
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = mkPkgs system;
          runit = pkgs.callPackage ./pkgs/runit { };
          runix = pkgs.callPackage ./pkgs/runix { };
          runix-install = pkgs.callPackage ./pkgs/runix-install { };
          bspwm = pkgs.callPackage ./pkgs/window-managers/bspwm.nix { };
          hyprland = pkgs.callPackage ./pkgs/window-managers/hyprland.nix { };
          labwc = pkgs.callPackage ./pkgs/window-managers/labwc.nix { };
          niri = pkgs.callPackage ./pkgs/window-managers/niri.nix { };
          qtile = pkgs.callPackage ./pkgs/window-managers/qtile.nix { };
          sxhkd = pkgs.callPackage ./pkgs/window-managers/sxhkd.nix { };
          consoleSource = pkgs.writeText "runix-console.c" ''
            #include <errno.h>
            #include <fcntl.h>
            #include <stdio.h>
            #include <stdlib.h>
            #include <sys/ioctl.h>
            #include <termios.h>
            #include <unistd.h>

            int main(void) {
              int terminal;

              if (setsid() == -1) {
                perror("setsid");
                return 1;
              }

              terminal = open("/dev/ttyS0", O_RDWR);
              if (terminal == -1) {
                perror("open /dev/ttyS0");
                return 1;
              }
              if (ioctl(terminal, TIOCSCTTY, 1) == -1) {
                perror("TIOCSCTTY");
                return 1;
              }
              if (dup2(terminal, STDIN_FILENO) == -1
                  || dup2(terminal, STDOUT_FILENO) == -1
                  || dup2(terminal, STDERR_FILENO) == -1) {
                perror("dup2");
                return 1;
              }
              if (terminal > STDERR_FILENO) close(terminal);
              if (tcsetpgrp(STDIN_FILENO, getpgrp()) == -1) {
                perror("tcsetpgrp");
                return 1;
              }

               setenv("TERM", "dumb", 1);
              setenv("HOME", "/root", 1);
              setenv("USER", "root", 1);
              if (chdir("/root") == -1) {
                perror("chdir /root");
                return 1;
              }
              execl("${pkgs.bashInteractive}/bin/bash", "bash", "--noprofile", "--norc", "-i", NULL);
              perror("exec bash");
              return 1;
            }
          '';
          consoleShell = pkgs.runCommandCC "runix-console" { } ''
            $CC -O2 -Wall -Wextra -Werror -o "$out" ${consoleSource}
          '';
          vm = self.lib.runixSystem {
            inherit system;
            modules = [
              {
                runix.virtualMachine.enable = true;
                runix.virtualMachine.qemuPackage = nixpkgs.legacyPackages.${system}.qemu_test;
                runix.services.console.command = "${consoleShell}";
              }
            ];
          };
        in
        {
          default = runit;
          inherit
            bspwm
            hyprland
            labwc
            niri
            qtile
            runit
            runix
            runix-install
            sxhkd
            ;
        }
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          inherit (vm.config.runix.build) vm;
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = mkPkgs system;
          example = self.lib.runixSystem {
            inherit system;
            modules = [ ./examples/configuration.nix ];
          };
          serviceTest = self.lib.runixSystem {
            inherit system;
            modules = [
              {
                services.mdevd.enable = false;
                runix.services = {
                  nix-daemon.enable = false;
                  never = {
                    script = ''printf . >> "$TEST_ROOT/never"; exit 1'';
                    restart = "never";
                  };
                  success = {
                    script = ''printf . >> "$TEST_ROOT/success"'';
                    restart = "on-failure";
                  };
                  retry = {
                    script = ''
                      printf . >> "$TEST_ROOT/retry"
                      test "$(wc -c < "$TEST_ROOT/retry")" -ge 2
                    '';
                    restart = "on-failure";
                  };
                };
              }
            ];
          };
        in
        {
          services =
            pkgs.runCommand "runix-services-test"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.coreutils
                  serviceTest.config.runix.runit.package
                ];
              }
              ''
                bash ${./tests/services.sh} ${serviceTest.config.runix.build.serviceTree}
                touch "$out"
              '';
          activation =
            pkgs.runCommand "runix-activation-test"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.findutils
                  pkgs.gnugrep
                  pkgs.shellcheck
                ];
              }
              ''
                bash ${./tests/activation.sh} ${./src/activate-etc.sh}
                shellcheck --shell=bash ${./src/activate-etc.sh} ${./tests/activation.sh} ${./tests/services.sh}
                touch "$out"
              '';
          inherit (self.packages.${system}) runix runix-install;
        }
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          generated-shell-syntax = pkgs.runCommand "runix-generated-shell-syntax" { } ''
            ${nixpkgs.lib.concatMapStringsSep "\n"
              (
                name:
                let
                  script = pkgs.writeText "runix-${name}-syntax.sh" (
                    builtins.unsafeDiscardStringContext example.config.runix.build.${name}.text
                  );
                in
                "${pkgs.bash}/bin/bash -n ${script}"
              )
              [
                "activation"
                "switchToConfiguration"
                "rollback"
                "installBootLoader"
              ]
            }
            touch "$out"
          '';
          example-evaluation = pkgs.writeText "runix-example-evaluation" (
            builtins.unsafeDiscardStringContext example.config.runix.build.system.drvPath
          );
        }
      );

      nixosModules.default = ./src;

      lib.runixSystem =
        {
          system,
          modules ? [ ],
        }:
        let
          pkgs = mkPkgs system;
          evaluated = nixpkgs.lib.evalModules {
            specialArgs = { inherit pkgs; };
            modules = [ ./src ] ++ modules;
          };
          failures = builtins.filter (item: !item.assertion) evaluated.config.assertions;
        in
        assert nixpkgs.lib.assertMsg (failures == [ ]) (
          nixpkgs.lib.concatMapStringsSep "\n" (item: item.message) failures
        );
        evaluated // { inherit pkgs; };

      formatter = forAllSystems (system: (mkPkgs system).nixfmt-tree);
    };
}

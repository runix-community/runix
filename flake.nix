{
  description = "Runix, a runit-powered operating system built with Nix";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.runixpkgs = {
    url = "github:runix-community/runixpkgs";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { self, nixpkgs, runixpkgs }:
    let
      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      mkPkgsWith =
        system: config:
        import nixpkgs {
          inherit system config;
          overlays = [ runixpkgs.overlays.default ];
        };
      mkPkgs = system: mkPkgsWith system { };
    in
    {
      overlays.default = runixpkgs.overlays.default;

      packages = forAllSystems (
        system:
        let
           pkgs = mkPkgs system;
           desktopPackages = import ./pkgs/desktop.nix { inherit pkgs; };
           fetchPackages = import ./pkgs/fetch.nix { inherit pkgs; };
           runit = pkgs.callPackage ./pkgs/runit { };
          runix = pkgs.callPackage ./pkgs/runix { };
          runix-install = pkgs.callPackage ./pkgs/runix-install { };
          runix-installer = pkgs.callPackage ./pkgs/runix-installer { inherit runix-install; };
          runixisogen = pkgs.callPackage ./pkgs/runixisogen { };
           bspwm = pkgs.bspwm;
           inherit (fetchPackages) fastfetch fastfetch-unwrapped pfetch;
           inherit (desktopPackages) hyprland labwc niri;
           inherit (pkgs) zwwm shojiwm driftwm;
          qtile = pkgs.python3Packages.qtile;
          sxhkd = pkgs.sxhkd;
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
          consoleShell = pkgs.runCommand "runix-console" { nativeBuildInputs = [ pkgs.clang ]; } ''
            clang -O2 -Wall -Wextra -Werror -o "$out" ${consoleSource}
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
          # A typical desktop install: CI builds it so everything an installed
          # desktop needs (SDDM, Weston, Hyprland, zwwm, the system itself) is
          # in the binary cache instead of compiled during the install.
          desktopSystem = self.lib.runixSystem {
            inherit system;
            modules = [
              {
                fileSystems."/" = {
                  device = "/dev/disk/by-label/runix-root";
                  fsType = "ext4";
                };
                runix.desktop.enable = true;
                programs.zwwm.enable = true;
                runix.systemServices.wifi.enable = true;
              }
            ];
          };
          live = self.lib.runixSystem {
            inherit system;
            modules = [ { runix.iso.enable = true; } ];
          };
        in
        {
          default = runit;
          inherit
             bspwm
             driftwm
             fastfetch
             fastfetch-unwrapped
             hyprland
            labwc
             niri
             pfetch
             qtile
            runit
            runix
            runix-install
            runix-installer
            runixisogen
             sxhkd
             shojiwm
             zwwm
            ;
        }
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          inherit (vm.config.runix.build) vm;
          desktop-system = desktopSystem.config.runix.build.system;
          inherit (live.config.runix.build) iso;
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
          # Programs made with mkProgram: a tool, and a compositor that is the
          # desktop's only one.
          customProgramSystem = self.lib.runixSystem {
            inherit system;
            modules = [
              (self.lib.mkProgram {
                name = "hello";
                package = pkgs: pkgs.hello;
                extraConfig = cfg: { runix.environmentVariables.RUNIX_TEST_HELLO = "${cfg.package}"; };
              })
              (self.lib.mkProgram {
                name = "sway";
                package = pkgs: pkgs.sway;
                session = true;
              })
              {
                fileSystems."/" = { device = "/dev/vda"; fsType = "ext4"; };
                programs.hello.enable = true;
                programs.sway.enable = true;
                programs.hyprland.enable = false;
                runix.desktop.enable = true;
              }
            ];
          };
          # A system that takes a service from another flake, the way users do.
          serviceFlake = import ./templates/service/flake.nix;
          flakeServiceSystem = self.lib.runixSystem {
            inherit system;
            modules = [
              (serviceFlake.outputs { self = null; }).runixModules.default
              {
                services.hello.enable = true;
                services.hello.greeting = "flake check";
              }
            ];
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
          custom-program =
            let
              built = customProgramSystem.config;
            in
            assert built.runix.wayland.enable;
            assert builtins.elem built.programs.sway.package built.runix.wayland.sessionPackages;
            assert builtins.elem built.programs.hello.package built.runix.packages;
            assert built.runix.environmentVariables.RUNIX_TEST_HELLO == "${built.programs.hello.package}";
            pkgs.writeText "runix-custom-program-test" "ok";
          flake-service =
            pkgs.runCommand "runix-flake-service-test" { }
              ''
                tree=${flakeServiceSystem.config.runix.build.serviceTree}
                test -x "$tree/hello/run"
                body=$(grep -o '/nix/store/[^ ]*-runix-service-hello-body' "$tree/hello/run")
                grep -q "flake check" "$body"
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
          inherit (self.packages.${system})
            runix
            runix-install
            runix-installer
            runixisogen
            ;
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

      # Other flakes ship services and settings for Runix as `runixModules`;
      # `nix flake init -t github:runix-community/runix#service` starts one.
      templates.service = {
        path = ./templates/service;
        description = "A flake that adds a runit service to Runix systems";
      };
      templates.program = {
        path = ./templates/program;
        description = "A flake that adds programs.<name> modules to Runix systems";
      };
      templates.default = self.templates.service;

      lib.mkPkgs = mkPkgs;
      lib.mkPkgsWith = mkPkgsWith;
      # A programs.<name> module for any package; see lib/mk-program.nix.
      lib.mkProgram = import ./lib/mk-program.nix;

      lib.runixSystem =
        {
          system,
          modules ? [ ],
          specialArgs ? { },
          # nixpkgs' config, such as allowUnfreePredicate for the NVIDIA driver.
          nixpkgsConfig ? { },
          pkgs ? mkPkgsWith system nixpkgsConfig,
        }:
        let
          evaluated = nixpkgs.lib.evalModules {
            specialArgs = { inherit pkgs runixpkgs; } // specialArgs;
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

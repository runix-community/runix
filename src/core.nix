{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.runix;

  userType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        uid = lib.mkOption {
          type = lib.types.int;
          description = "Numeric user ID.";
        };
        gid = lib.mkOption {
          type = lib.types.int;
          default = 100;
          description = "Numeric primary group ID.";
        };
        home = lib.mkOption {
          type = lib.types.str;
          default = "/home/${name}";
          description = "Home directory.";
        };
        shell = lib.mkOption {
          type = lib.types.str;
          default = "${pkgs.bashInteractive}/bin/bash";
          description = "Login shell.";
        };
        description = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "GECOS account description.";
        };
        passwordHash = lib.mkOption {
          type = lib.types.str;
          default = "!";
          description = "Password hash for /etc/shadow; ! locks password login.";
        };
        passwordHashFile = lib.mkOption {
          type = lib.types.nullOr (lib.types.strMatching "/.*");
          default = null;
          description = "Absolute runtime path to a root-readable password hash file, never copied into the Nix store. Overrides passwordHash.";
        };
        extraGroups = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Supplementary groups for the user.";
        };
      };
    }
  );

  groupType = lib.types.submodule {
    options.gid = lib.mkOption {
      type = lib.types.int;
      description = "Numeric group ID.";
    };
  };

  rootUser = {
    uid = 0;
    gid = 0;
    home = "/root";
    shell = "${pkgs.bashInteractive}/bin/bash";
    description = "System administrator";
    passwordHash = "!";
    passwordHashFile = null;
    extraGroups = [ ];
  };

  normalizedUsers = {
    root = rootUser;
  }
  // cfg.users;

  passwd = lib.concatMapAttrsStringSep "\n" (
    name: user:
    "${name}:x:${toString user.uid}:${toString user.gid}:${user.description}:${user.home}:${user.shell}"
  ) normalizedUsers;

  shadow = lib.concatMapAttrsStringSep "\n" (
    name: user: "${name}:${user.passwordHash}:1::::::"
  ) normalizedUsers;

  configuredGroups = {
    root.gid = 0;
    users.gid = 100;
  }
  // cfg.groups;
  configuredGroupIds = map (group: group.gid) (lib.attrValues configuredGroups);
  primaryGroupIds = lib.unique (map (user: user.gid) (lib.attrValues normalizedUsers));
  implicitGroups = builtins.listToAttrs (
    map (gid: {
      name = "group${toString gid}";
      value.gid = gid;
    }) (builtins.filter (gid: !(lib.elem gid configuredGroupIds)) primaryGroupIds)
  );
  normalizedGroups = configuredGroups // implicitGroups;
  group = lib.concatMapAttrsStringSep "\n" (
    name: group:
    let
      members = lib.attrNames (
        lib.filterAttrs (_: user: user.gid == group.gid || lib.elem name user.extraGroups) normalizedUsers
      );
    in
    "${name}:x:${toString group.gid}:${lib.concatStringsSep "," members}"
  ) normalizedGroups;
  gshadow = lib.concatMapAttrsStringSep "\n" (
    name: _:
    "${name}:x::${
      lib.concatStringsSep "," (
        lib.attrNames (lib.filterAttrs (_: user: lib.elem name user.extraGroups) normalizedUsers)
      )
    }"
  ) normalizedGroups;

  packages = lib.unique cfg.packages;
  environment = pkgs.buildEnv {
    name = "runix-environment";
    paths = packages;
    pathsToLink = [
      "/bin"
      "/sbin"
      "/share"
    ];
    ignoreCollisions = true;
  };
  packageManifest = pkgs.writeText "runix-package-manifest.json" (
    builtins.toJSON (
      map (package: {
        name = lib.getName package;
        version = lib.getVersion package;
        path = toString package;
      }) packages
    )
  );
  pamLogin = pkgs.writeText "runix-pam-login" ''
    auth required ${pkgs.linux-pam}/lib/security/pam_unix.so
    account required ${pkgs.linux-pam}/lib/security/pam_unix.so
    password required ${pkgs.linux-pam}/lib/security/pam_unix.so
    session required ${pkgs.linux-pam}/lib/security/pam_unix.so
  '';
  unixChkpwdWrapperSource = pkgs.writeText "runix-unix-chkpwd-wrapper.c" ''
    #include <stdio.h>
    #include <unistd.h>

    int main(int argc, char **argv) {
      (void)argc;
      execv("${pkgs.linux-pam}/bin/unix_chkpwd", argv);
      perror("unix_chkpwd");
      return 127;
    }
  '';
  unixChkpwdWrapper = pkgs.runCommand "runix-unix-chkpwd-wrapper" { nativeBuildInputs = [ pkgs.clang ]; } ''
    clang -O2 -Wall -Wextra -Werror ${unixChkpwdWrapperSource} -o "$out"
  '';
in
{
  options = {
    assertions = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
      internal = true;
    };

    runix = {
      hostName = lib.mkOption {
        type = lib.types.strMatching "[a-zA-Z0-9][a-zA-Z0-9.-]*";
        default = "runix";
        description = "System host name.";
      };

      kernel = {
        packageSet = lib.mkOption {
          type = lib.types.raw;
          default = pkgs.linuxPackages.extend (_: super: {
            kernel = super.kernel.override (args: {
              structuredExtraConfig = (args.structuredExtraConfig or { }) // {
                CRYPTO_BLAKE2B = lib.kernel.yes;
                CRYPTO_CRC32C = lib.kernel.yes;
                CRYPTO_SHA256 = lib.kernel.yes;
                CRYPTO_XXHASH = lib.kernel.yes;
              };
            });
          });
          description = "Kernel package set used to select the kernel and matching external modules.";
        };
        package = lib.mkOption {
          type = lib.types.package;
          default = cfg.kernel.packageSet.kernel;
          description = "Linux kernel package.";
        };
        parameters = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Kernel command-line parameters.";
        };
        modules = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Kernel modules loaded after mounting the root filesystem.";
        };
        modulePackages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [ ];
          description = "Out-of-tree kernel module packages included in the boot module tree.";
        };
        firmwarePackages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [ ];
          description = "Firmware packages included in the initial ramdisk.";
        };
      };

      users = lib.mkOption {
        type = lib.types.attrsOf userType;
        default = { };
        description = "Static local user accounts.";
      };

      groups = lib.mkOption {
        type = lib.types.attrsOf groupType;
        default = { };
        description = "Static local groups.";
      };

      preparationScripts = lib.mkOption {
        type = lib.types.listOf lib.types.lines;
        default = [ ];
        internal = true;
        description = "Offline-safe file and state preparation, run during installation and live activation. Must not change the live kernel or start services.";
      };

      activationScripts = lib.mkOption {
        type = lib.types.listOf lib.types.lines;
        default = [ ];
        internal = true;
        description = "Runtime-only activation commands, skipped during offline installation.";
      };

      shutdownScripts = lib.mkOption {
        type = lib.types.listOf lib.types.lines;
        default = [ ];
        internal = true;
        description = "Commands contributed by modules to shutdown.";
      };

      packages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
        description = "Packages available in the system environment.";
      };

      environmentVariables = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Environment variables exported by the system profile.";
      };

      build = lib.mkOption {
        internal = true;
        default = { };
        type = lib.types.lazyAttrsOf lib.types.raw;
      };
    };
  };

  config = {
    assertions = lib.concatLists (
      lib.mapAttrsToList (
        name: user:
        map (groupName: {
          assertion = builtins.hasAttr groupName normalizedGroups;
          message = "runix user ${name} has unknown supplementary group ${groupName}";
        }) user.extraGroups
      ) normalizedUsers
    );

    runix = {
      kernel.modules = lib.mkBefore [
        "i8042"
        "atkbd"
        "loop"
      ];
      packages = [
        pkgs.bashInteractive
        pkgs.busybox
        pkgs.coreutils
        pkgs.iproute2
        pkgs.kmod
        pkgs.util-linux
        config.runix.runit.package
      ];
      preparationScripts = lib.mkBefore [
        ''
          mkdir -p /etc/pam.d /run/wrappers/bin
          ln -sfn ${pamLogin} /etc/pam.d/login
          ${pkgs.coreutils}/bin/install -m4755 -o root -g root \
            ${unixChkpwdWrapper} /run/wrappers/bin/unix_chkpwd
        ''
      ];
      build = {
        inherit
          environment
          group
          gshadow
          normalizedGroups
          normalizedUsers
          packageManifest
          passwd
          shadow
          ;
      };
    };
  };
}

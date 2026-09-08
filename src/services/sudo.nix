{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.sudo;
  sudoersSource = pkgs.writeText "runix-sudoers.in" ''
    Defaults env_reset
    Defaults env_keep += "NIX_CONFIG NIX_PATH TERM TERMINFO TERMINFO_DIRS"
    root ALL=(ALL:ALL) SETENV: ALL
    %wheel ALL=(ALL:ALL) SETENV: ALL
    ${cfg.extraConfig}
  '';
  sudoers = pkgs.runCommand "runix-sudoers" { } ''
    ${cfg.package}/sbin/visudo -c -f ${sudoersSource}
    cp ${sudoersSource} "$out"
  '';
  pamConfig = pkgs.writeText "runix-pam-sudo" ''
    auth required ${pkgs.linux-pam}/lib/security/pam_unix.so
    account required ${pkgs.linux-pam}/lib/security/pam_unix.so
    session required ${pkgs.linux-pam}/lib/security/pam_unix.so
  '';
in
{
  options.programs.sudo = {
    enable = lib.mkEnableOption "sudo privilege escalation";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.sudo;
      description = "Sudo package.";
    };
    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Additional validated sudoers configuration.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.runix.groups ? wheel;
        message = "programs.sudo requires a wheel group in runix.groups";
      }
    ];
    runix.packages = [ cfg.package ];
    runix.preparationScripts = [
      ''
        mkdir -p /etc/pam.d /run/wrappers/bin
        ln -sfn ${sudoers} /etc/sudoers
        ln -sfn ${pamConfig} /etc/pam.d/sudo
        ${pkgs.coreutils}/bin/install -m4755 ${cfg.package}/bin/sudo /run/wrappers/bin/sudo
        ln -sfn /run/wrappers/bin/sudo /run/wrappers/bin/sudoedit
      ''
    ];
  };
}

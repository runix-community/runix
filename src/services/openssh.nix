{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.runix.systemServices.openssh;
  sshdConfig = pkgs.writeText "runix-sshd-config" ''
    Port 22
    HostKey /var/lib/runix/ssh/ssh_host_ed25519_key
    HostKey /var/lib/runix/ssh/ssh_host_rsa_key
    PasswordAuthentication ${if cfg.passwordAuthentication then "yes" else "no"}
    PermitRootLogin ${if cfg.permitRootLogin then "yes" else "no"}
    UsePAM no
    PidFile /run/sshd.pid
    Subsystem sftp ${pkgs.openssh}/libexec/sftp-server
  '';
in
{
  options.runix.systemServices.openssh = {
    enable = lib.mkEnableOption "the OpenSSH daemon";
    passwordAuthentication = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether sshd accepts password authentication.";
    };
    permitRootLogin = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether root may log in over SSH.";
    };
  };
  config = lib.mkIf cfg.enable {
    runix.groups.sshd.gid = 74;
    runix.users.sshd = {
      uid = 74;
      gid = 74;
      home = "/var/empty";
      shell = "/bin/false";
    };
    runix.packages = [ pkgs.openssh ];
    runix.preparationScripts = [
      ''
        mkdir -p /run/sshd /var/empty /var/lib/runix/ssh
        if [ ! -s /var/lib/runix/ssh/ssh_host_ed25519_key ]; then
          ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -f /var/lib/runix/ssh/ssh_host_ed25519_key
        fi
        if [ ! -s /var/lib/runix/ssh/ssh_host_rsa_key ]; then
          ${pkgs.openssh}/bin/ssh-keygen -q -t rsa -b 4096 -N "" -f /var/lib/runix/ssh/ssh_host_rsa_key
        fi
      ''
    ];
    runix.services.sshd.command = "${pkgs.openssh}/bin/sshd -D -e -f ${sshdConfig}";
  };
}

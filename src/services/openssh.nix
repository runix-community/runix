{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.runix.systemServices.openssh;
  pamConfig = pkgs.writeText "runix-pam-sshd" ''
    auth required ${pkgs.linux-pam}/lib/security/pam_unix.so
    account required ${pkgs.linux-pam}/lib/security/pam_unix.so
    session required ${pkgs.linux-pam}/lib/security/pam_env.so conffile=/etc/security/pam_env.conf readenv=0
    session required ${pkgs.linux-pam}/lib/security/pam_unix.so
  '';
  sshdConfig = pkgs.writeText "runix-sshd-config" ''
    Port 22
    HostKey /var/lib/runix/ssh/ssh_host_ed25519_key
    HostKey /var/lib/runix/ssh/ssh_host_rsa_key
    PasswordAuthentication ${if cfg.passwordAuthentication then "yes" else "no"}
    # Through PAM, keyboard-interactive is a password login too.
    KbdInteractiveAuthentication ${if cfg.passwordAuthentication then "yes" else "no"}
    PermitRootLogin ${if cfg.permitRootLogin then "yes" else "no"}
    UsePAM yes
    AuthorizedKeysFile .ssh/authorized_keys /etc/ssh/authorized_keys.d/%u
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
    authorizedKeys = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = { };
      example = {
        alice = [ "ssh-ed25519 AAAAC3... alice@laptop" ];
      };
      description = "Public keys, by user name, that may log in as that user, besides ~/.ssh/authorized_keys.";
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
        mkdir -p /etc/pam.d /run/sshd /var/empty /var/lib/runix/ssh
        # Copies, not links: sshd checks the owner and mode of key files.
        rm -rf /etc/ssh/authorized_keys.d
        install -d -m 0755 /etc/ssh/authorized_keys.d
        ${lib.concatMapAttrsStringSep "\n" (
          user: keys:
          "install -m 0444 ${pkgs.writeText "authorized-keys-${user}" (lib.concatLines keys)} /etc/ssh/authorized_keys.d/${lib.escapeShellArg user}"
        ) cfg.authorizedKeys}
        ln -sfn ${pamConfig} /etc/pam.d/sshd
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

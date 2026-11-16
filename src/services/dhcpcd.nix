{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.runix.systemServices.dhcpcd;
  dhcpcdConfig = pkgs.writeText "runix-dhcpcd.conf" ''
    hostname
    option domain_name_servers, domain_name, domain_search, host_name
    option classless_static_routes, interface_mtu
    nohook lookup-hostname
    nohook hostname
    denyinterfaces lo peth* vif* tap* tun* virbr* vnet* vboxnet* sit*
  '';
in
{
  options.runix.systemServices.dhcpcd.enable = lib.mkEnableOption "dhcpcd network configuration";

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !config.runix.systemServices.networkManager.enable;
        message = "dhcpcd and NetworkManager cannot manage interfaces at the same time";
      }
    ];
    runix.groups.dhcpcd.gid = 992;
    runix.users.dhcpcd = {
      uid = 992;
      gid = 992;
      home = "/var/lib/dhcpcd";
      shell = "/bin/false";
    };
    runix.packages = [ pkgs.dhcpcd ];
    runix.preparationScripts = [
      ''
        mkdir -p /run/dhcpcd /var/db/dhcpcd /var/lib/dhcpcd
        chown dhcpcd:dhcpcd /var/db/dhcpcd /var/lib/dhcpcd
        ln -sfn ${dhcpcdConfig} /etc/dhcpcd.conf
        # Until a lease names the network's own DNS servers, which dhcpcd
        # then writes here: some networks block outside resolvers.
        rm -f /etc/resolv.conf
        printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\noptions timeout:2 attempts:3\n' > /etc/resolv.conf
      ''
    ];
    runix.services.dhcpcd = {
      command = "${pkgs.dhcpcd}/bin/dhcpcd --nodev -B -q -f ${dhcpcdConfig}";
      # What dhcpcd's resolv.conf hook calls.
      path = [
        pkgs.coreutils
        pkgs.diffutils
        pkgs.gnused
        pkgs.util-linux
      ];
      after = [ "mdevd-coldplug" ];
    };
  };
}

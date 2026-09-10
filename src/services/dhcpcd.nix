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
        rm -f /etc/resolv.conf
        printf 'nameserver 1.1.1.1\n' > /etc/resolv.conf
      ''
    ];
    runix.services.dhcpcd = {
      command = "${pkgs.dhcpcd}/bin/dhcpcd -B -f ${dhcpcdConfig}";
      after = [ "mdevd-coldplug" ];
    };
  };
}

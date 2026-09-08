{
  config,
  lib,
  pkgs,
  ...
}:
let
  valueType = lib.types.nullOr (
    lib.types.oneOf [
      lib.types.bool
      lib.types.int
      lib.types.str
    ]
  );
  settings = lib.filterAttrs (_: value: value != null) config.boot.kernel.sysctl;
  renderValue = value: if lib.isBool value then lib.boolToString value else toString value;
  configFile = pkgs.writeText "runix-sysctl.conf" (
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: value: "${name} = ${renderValue value}") settings
    )
    + "\n"
  );
in
{
  options.boot.kernel.sysctl = lib.mkOption {
    type = lib.types.attrsOf valueType;
    default = { };
    example = {
      "net.ipv4.tcp_syncookies" = true;
      "vm.swappiness" = 10;
    };
    description = "Linux kernel parameters applied during system activation.";
  };

  config = {
    boot.kernel.sysctl = {
      "kernel.kptr_restrict" = lib.mkDefault 1;
      "vm.max_map_count" = lib.mkDefault 1048576;
    };
    runix.packages = [ pkgs.procps ];
    runix.preparationScripts = [
      ''
        mkdir -p /etc/sysctl.d
        ln -sfn ${configFile} /etc/sysctl.d/60-runix.conf
      ''
    ];
    runix.activationScripts = [ "${pkgs.procps}/bin/sysctl -q -p ${configFile}" ];
  };
}

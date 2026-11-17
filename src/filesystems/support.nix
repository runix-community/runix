{
  config,
  lib,
  pkgs,
  ...
}:
let
  table = import ./table.nix pkgs;
  mounted = lib.mapAttrsToList (_: fileSystem: fileSystem.fsType) config.fileSystems;
  used = lib.unique (mounted ++ config.runix.supportedFilesystems);
  known = builtins.filter (type: table ? ${type}) used;
  network = builtins.filter (type: table.${type}.network or false) mounted;
  util = "${pkgs.util-linux}/bin";
in
{
  options.runix.supportedFilesystems = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    example = [
      "ntfs3"
      "exfat"
      "nfs4"
    ];
    description = ''
      Filesystem types to have the tools for (mkfs, fsck, mount helpers)
      even when nothing in fileSystems mounts them, such as for USB drives
      or a Windows partition mounted by hand. Types used in fileSystems are
      supported without being listed here.
    '';
  };

  config = lib.mkMerge [
    {
      runix.packages = lib.concatMap (type: table.${type}.packages) known;
    }
    (lib.mkIf (network != [ ]) {
      # Activation skips these (mount -a -O no_netdev); this service mounts
      # them once the network answers, and keeps trying until it does.
      runix.services.network-filesystems.script = ''
        until ${util}/mount -a -O _netdev; do
          ${pkgs.coreutils}/bin/sleep 5
        done
        exec ${pkgs.coreutils}/bin/sleep infinity
      '';
      # Unmount them while the network is still up, or shutdown hangs.
      runix.shutdownScripts = lib.mkBefore [
        "${util}/umount -a -l -O _netdev 2>/dev/null || true"
      ];
    })
  ];
}

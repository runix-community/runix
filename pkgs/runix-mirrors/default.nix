{
  coreutils,
  curl,
  gawk,
  gnused,
  runit,
  writeShellApplication,
}:
writeShellApplication {
  name = "runix-mirrors";
  runtimeInputs = [
    coreutils
    curl
    gawk
    gnused
    runit
  ];
  # The script checks curl's exit status itself.
  bashOptions = [ ];
  text = builtins.readFile ./runix-mirrors.sh;
  meta.description = "Switch Nix to a working mirror when cache.nixos.org is blocked or slow";
}

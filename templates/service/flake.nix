{
  description = "A runit service for Runix";

  # No nixpkgs input: the module gets `pkgs` from the Runix system that
  # imports it, so the service is built with the same packages as the rest
  # of that system.
  outputs =
    { self }:
    {
      runixModules.default = ./module.nix;
    };
}

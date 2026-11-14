{
  btrfs-progs,
  coreutils,
  curl,
  dosfstools,
  e2fsprogs,
  flakeUrl ? "github:runix-community/runix",
  gptfdisk,
  lib,
  makeWrapper,
  mkpasswd,
  runix-install,
  rustPlatform,
  tzdata,
  util-linux,
}:
rustPlatform.buildRustPackage {
  pname = "runix-installer";
  version = "0.1.0";
  src = lib.cleanSource ./.;
  cargoLock.lockFile = ./Cargo.lock;

  nativeBuildInputs = [ makeWrapper ];

  postInstall = ''
    wrapProgram "$out/bin/runix-installer" \
      --prefix PATH : ${
        lib.makeBinPath [
          btrfs-progs
          coreutils
          curl
          dosfstools
          e2fsprogs
          gptfdisk
          mkpasswd
          runix-install
          util-linux
        ]
      } \
      --set RUNIX_ZONEINFO ${tzdata}/share/zoneinfo \
      --set-default RUNIX_INSTALL_FLAKE ${lib.escapeShellArg flakeUrl}
  '';

  meta = {
    description = "Interactive terminal installer for Runix";
    license = lib.licenses.bsd3;
    mainProgram = "runix-installer";
    platforms = lib.platforms.linux;
  };
}

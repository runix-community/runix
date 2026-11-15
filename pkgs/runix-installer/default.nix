{
  btrfs-progs,
  coreutils,
  curl,
  dosfstools,
  e2fsprogs,
  flakeUrl ? "github:runix-community/runix",
  gptfdisk,
  kmod,
  lib,
  logPasteUrl ? "https://paste.rs/",
  makeWrapper,
  mkpasswd,
  ncurses,
  pkg-config,
  runix-install,
  clangStdenv,
  tzdata,
  util-linux,
  zfs,
}:
clangStdenv.mkDerivation {
  pname = "runix-installer";
  version = "0.2.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Makefile
      ./src
      ./tests
    ];
  };

  nativeBuildInputs = [
    makeWrapper
    pkg-config
  ];
  buildInputs = [ ncurses ];

  makeFlags = [ "PREFIX=$(out)" ];
  enableParallelBuilding = true;
  doCheck = true;
  checkTarget = "check";

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
          kmod
          mkpasswd
          runix-install
          util-linux
          zfs
        ]
      } \
      --set RUNIX_ZONEINFO ${tzdata}/share/zoneinfo \
      --set-default RUNIX_INSTALL_FLAKE ${lib.escapeShellArg flakeUrl} \
      --set-default RUNIX_LOG_PASTE_URL ${lib.escapeShellArg logPasteUrl}
  '';

  meta = {
    description = "Interactive terminal installer for Runix";
    license = lib.licenses.bsd3;
    mainProgram = "runix-installer";
    platforms = lib.platforms.linux;
  };
}

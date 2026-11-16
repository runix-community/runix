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
  linkFarm,
  python3Minimal,
  writeText,
  logPasteUrl ? "https://paste.rs/",
  # Extra catalogs, by language code: a JSON file, or the catalog as an
  # attribute set ({ language = "Deutsch"; strings = { ... }; }).
  translations ? { },
  # The language the installer starts in; null starts in English.
  language ? null,
  # Preselected choices and extra Nix for installed systems; see
  # runix.iso.installer.settings.
  settings ? { },
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
let
  catalogs = linkFarm "runix-installer-translations" (
    lib.mapAttrsToList (code: catalog: {
      name = "${code}.json";
      path =
        if builtins.isAttrs catalog then
          writeText "runix-installer-${code}.json" (builtins.toJSON catalog)
        else
          catalog;
    }) translations
  );
  settingsFile = writeText "runix-installer-settings.json" (
    builtins.toJSON (lib.filterAttrs (_: value: value != null && value != "") settings)
  );
in
clangStdenv.mkDerivation {
  pname = "runix-installer";
  version = "0.2.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Makefile
      ./src
      ./tests
      ./catalog-template.json
      ./extract-strings.py
      (lib.fileset.maybeMissing ./translations)
    ];
  };

  nativeBuildInputs = [
    makeWrapper
    pkg-config
  ];
  nativeCheckInputs = [ python3Minimal ];
  buildInputs = [ ncurses ];

  makeFlags = [ "PREFIX=$(out)" ];
  enableParallelBuilding = true;
  doCheck = true;
  checkTarget = "check";
  # The template must list exactly the text the installer shows; refresh it
  # with: python3 extract-strings.py src catalog-template.json > new.json
  postCheck = ''
    python3 extract-strings.py src catalog-template.json > fresh.json
    if ! cmp -s fresh.json catalog-template.json; then
      echo "catalog-template.json is out of date with the installer's text:" >&2
      diff catalog-template.json fresh.json >&2 || true
      exit 1
    fi
  '';

  postInstall = ''
    mkdir -p $out/share/runix-installer/translations
    install -m0644 catalog-template.json $out/share/runix-installer/
    if [ -d translations ]; then
      install -m0644 translations/*.json $out/share/runix-installer/translations/
    fi
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
      --set-default RUNIX_LOG_PASTE_URL ${lib.escapeShellArg logPasteUrl} \
      --set-default RUNIX_INSTALLER_TRANSLATIONS "$out/share/runix-installer/translations:${catalogs}" \
      ${lib.optionalString (settings != { }) "--set-default RUNIX_INSTALLER_SETTINGS ${settingsFile}"} \
      ${lib.optionalString (language != null) "--set-default RUNIX_INSTALLER_LANGUAGE ${lib.escapeShellArg language}"}
  '';

  meta = {
    description = "Interactive terminal installer for Runix";
    license = lib.licenses.bsd3;
    mainProgram = "runix-installer";
    platforms = lib.platforms.linux;
  };
}

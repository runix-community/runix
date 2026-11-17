{
  lib,
  stdenv,
  fetchurl,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "runit";
  version = "2.3.1";

  src = fetchurl {
    url = "https://smarden.org/runit/runit-${finalAttrs.version}.tar.gz";
    hash = "sha256-Y08jyMTR1EAEO+D+ko3fkEYmKJ6Xv+fFgm6TqvLMb+k=";
  };

  patches = [ ./fix-ar-ranlib.patch ];
  sourceRoot = "admin/runit-${finalAttrs.version}";

  outputs = [
    "out"
    "man"
  ];

  postPatch = ''
    sed -i "s,\(#define RUNIT\) .*,\1 \"$out/bin/runit\"," src/runit.h

    # Runix's services live in /run/runit/service: sv finds them there
    # without SVDIR, as from sudo, su or a script.
    substituteInPlace src/sv.c --replace-fail 'char *varservice ="/service/";' 'char *varservice ="/run/runit/service/";'

    # runit's own console lines in Runix's boot colors: green steps, yellow
    # warnings, red failures, and a plain version instead of the $Id$ hash.
    substituteInPlace src/runit.c \
      --replace-fail '#define INFO "- runit: "' '#define INFO "\033[1;32m::\033[0m runit: "' \
      --replace-fail '#define WARNING "- runit: warning: "' '#define WARNING "\033[1;33m!!\033[0m runit: warning: "' \
      --replace-fail '#define FATAL "- runit: fatal: "' '#define FATAL "\033[1;31m!!\033[0m runit: fatal: "' \
      --replace-fail '"$Id: c66c1e3b98d1b630bd51b1d56aaed5c2994e8c9d $"' '"${finalAttrs.version}"'
    # The test reads runit's output through cat -v.
    printf '%s\n' '^[[1;31m!!^[[0m runit: fatal: must be run as process no 1.' 111 > src/runit.dist

    # This test assumes access to the host user database.
    sed -i '/\.\/chkshsgr/d' src/Makefile

    # Use stdenv's dynamic linking instead of upstream's static default.
    sed -i 's/-static//g' src/Makefile
  '';

  preBuild = ''
    cd src
    printf '%s\n' "${stdenv.cc.targetPrefix}cc" > conf-cc
    printf '%s\n' "${stdenv.cc.targetPrefix}cc" > conf-ld
  '';

  enableParallelBuilding = true;
  doCheck = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin" "$man/share/man/man8"
    cp -t "$out/bin" $(< ../package/commands)
    cp -r ../man/. "$man/share/man/man8/"

    runHook postInstall
  '';

  meta = {
    description = "UNIX init scheme with service supervision";
    homepage = "https://smarden.org/runit/";
    license = lib.licenses.bsd3;
    platforms = lib.platforms.unix;
    mainProgram = "runit";
  };
})

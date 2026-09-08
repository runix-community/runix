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

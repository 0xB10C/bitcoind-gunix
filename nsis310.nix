# NSIS 3.10 built the GUIX way (gnu/packages/installers.scm make-nsis): the
# makensis compiler is native, but the installer STUBS + plugins are
# CROSS-compiled to x86_64-w64-mingw32 so they end up byte-identical to GUIX's
# (the stub is prepended to every setup.exe). GUIX uses its default cross-gcc
# (gcc-11 = 11.4.0) + cross-binutils (2.41) + cross-libc (mingw-w64 12.0.0);
# `nsisCC` is exactly that toolchain (NoFp-wrapped, see default.nix).
#
# Unlike nixpkgs' nsis (which SKIPSTUBS=all and ships the prebuilt official
# Windows stubs), we build the stubs from source — the official stubs are
# compiled by the NSIS project, not GUIX, so they don't match.
{ lib
, stdenv
, fetchurl
, scons
, zlib
, nsisCC          # the gcc 11.4.0 mingw cross (wrapped; provides <triple>-gcc/g++)
, mingwInclude    # mingw-w64 CRT headers dir (PREFIX_PLUGINAPI_INC)
, mingwLib        # mingw-w64 CRT libs dir   (PREFIX_PLUGINAPI_LIB)
, hostTriple      # "x86_64-w64-mingw32"
, targetArch ? "amd64"
, nsisTargetType ? "TARGET_AMD64"
}:

let
  # GUIX's exact scons flags (make-nsis #:scons-flags). The stub/plugin/util
  # cross-compile is driven by XGCC_W32_PREFIX; makensis builds natively.
  sconsFlags = [
    "UNICODE=yes"
    ''SKIPUTILS=MakeLangId,Makensisw,NSIS Menu,SubStart,zip2exe''
    "SKIPDOC=COPYING"
    "STRIP_CP=no"
    "PREFIX=${placeholder "out"}"
    "TARGET_ARCH=${targetArch}"
    "XGCC_W32_PREFIX=${hostTriple}-"
    "PREFIX_PLUGINAPI_INC=${mingwInclude}/"
    "PREFIX_PLUGINAPI_LIB=${mingwLib}/"
  ];
in
stdenv.mkDerivation {
  pname = "nsis";
  version = "3.10";

  src = fetchurl {
    url = "https://prdownloads.sourceforge.net/nsis/nsis-3.10-src.tar.bz2";
    # GUIX's hash (base32) for nsis-3.10-src.tar.bz2.
    sha256 = "15xj1izz3cmaw0mazsvfm8jpr132dyphlw5j0pszwimb0xilmd8i";
  };

  # GUIX's patch: SConstruct passes the real os.environ to the build env so
  # PATH / the cross toolchain are visible to the sub-compiles.
  patches = [ ./patches/nsis-env-passthru.patch ];

  nativeBuildInputs = [ scons nsisCC ];
  buildInputs = [ zlib ];

  # GUIX's vanilla cross-gcc applies none of nixpkgs' cc-wrapper hardenings;
  # the NoFp wrapper (nsisCC) already drops the frame-pointer injection, and
  # these drop the rest so the stub codegen matches GUIX's bare gcc-11 -O2.
  hardeningDisable = [
    "zerocallusedregs" "strictoverflow" "stackprotector"
    "stackclashprotection" "fortify" "fortify3" "format"
    "strictflexarrays1" "libcxxhardeningfast" "pic" "relro" "bindnow"
  ];

  # GUIX substitutes the (mis-detected) default target type in build.cpp.
  postPatch = ''
    substituteInPlace Source/build.cpp \
      --replace-fail "m_target_type=TARGET_X86UNICODE" "m_target_type=${nsisTargetType}"
  '';

  # zlib for the native makensis (its data-compression support).
  env = {
    APPEND_CPPPATH = "${zlib.dev}/include";
    APPEND_LIBPATH = "${zlib}/lib";
  };

  # SOURCE_DATE_EPOCH=1 (GUIX's container default). NSIS bakes its version into
  # the installer + uninstaller stubs as "v<date(SOURCE_DATE_EPOCH)>.cvs" when
  # no VERSION is given (GUIX passes none) → epoch 1 = "v01-Jan-1970.cvs", and
  # the stubs' PE TimeDateStamp = 1 (the setup.exe inherits both from the stub).
  # Must be set in preBuild: nixpkgs' unpack hook otherwise resets it to the
  # source tarball mtime (= NSIS 3.10's release date, 30-Mar-2024).
  preBuild = ''
    export SOURCE_DATE_EPOCH=1
  '';

  buildPhase = ''
    runHook preBuild
    scons ${lib.escapeShellArgs sconsFlags} \
      APPEND_CPPPATH="$APPEND_CPPPATH" APPEND_LIBPATH="$APPEND_LIBPATH" \
      -j"''${NIX_BUILD_CORES:-1}" \
      makensis stubs plugins utils
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    scons ${lib.escapeShellArgs sconsFlags} \
      APPEND_CPPPATH="$APPEND_CPPPATH" APPEND_LIBPATH="$APPEND_LIBPATH" \
      install-stubs install-plugins install-data install-utils \
      install-compiler install-conf
    runHook postInstall
  '';

  meta = {
    description = "NSIS 3.10 (GUIX-style: native makensis + cross-compiled stubs)";
    mainProgram = "makensis";
  };
}

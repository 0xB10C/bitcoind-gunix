# signapple — the pure-python Mach-O signature tool GUIX uses to apply
# Bitcoin Core's detached macOS code signatures (contrib/guix/libexec/
# codesign.sh). Versions pinned to GUIX's manifest.scm so the signed
# Mach-O output bytes match upstream: signapple @ 85bfcec, and its
# Mach-O parser elfesteem @ 2eb1e53 (GUIX overrides signapple's own
# pyproject pin with this commit, so we must too). asn1crypto, oscrypto
# (1.3.0) and certvalidator come from nixpkgs; certvalidator is only
# touched by signapple's verify path (imported, not used by `apply`).
{ lib
, python3Packages
, fetchFromGitHub
}:

let
  # signapple's `apply` verifies the result, exercising
  # certvalidator.ValidationContext(additional_critical_extensions=…) — a
  # keyword that only exists in achow101's FORK (GUIX manifest commit
  # a145bf25), not stock certvalidator. So we must use the fork.
  certvalidator = python3Packages.buildPythonPackage {
    pname = "certvalidator";
    version = "0.1-a145bf25";
    pyproject = true;
    build-system = [ python3Packages.setuptools ];
    src = fetchFromGitHub {
      owner = "achow101";
      repo = "certvalidator";
      rev = "a145bf25eb75a9f014b3e7678826132efbba6213";
      hash = "sha256-0yQGITuxvF75QOg+pY+k5tzKFvUeN3xpOmEUHfuZguM=";
    };
    propagatedBuildInputs = with python3Packages; [ asn1crypto oscrypto ];
    doCheck = false; # tests want oscryptotests (GUIX disables them too)
    pythonImportsCheck = [ "certvalidator" ];
  };

  elfesteem = python3Packages.buildPythonPackage {
    pname = "elfesteem";
    version = "0.1-2eb1e53";
    src = fetchFromGitHub {
      owner = "LRGH";
      repo = "elfesteem";
      rev = "2eb1e5384ff7a220fd1afacd4a0170acff54fe56";
      hash = "sha256-Jpfc5I7FmzVZymxeXNirVImKOc69TWGDRj8ESBm6ph8=";
    };
    # setup.py-based (setuptools); no tests (PYTHONPATH issues — GUIX
    # disables them too).
    pyproject = true;
    build-system = [ python3Packages.setuptools ];
    doCheck = false;
    pythonImportsCheck = [ "elfesteem" ];
  };
in
python3Packages.buildPythonApplication {
  pname = "signapple";
  version = "0.2.0-85bfcec";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "achow101";
    repo = "signapple";
    rev = "85bfcecc33d2773bc09bc318cec0614af2c8e287";
    hash = "sha256-z6OnIwgsONBpNRVZqpPf5QtQ+KET4gebwQNxiyiV2J8=";
  };

  build-system = [ python3Packages.poetry-core ];

  # signapple's pyproject pins git revs for these; the dependency *values*
  # don't affect `apply`'s output bytes, so use nixpkgs' packages (oscrypto
  # is 1.3.0, matching GUIX) + our elfesteem. Strip the git markers from
  # pyproject so poetry-core resolves against the installed packages.
  postPatch = ''
    substituteInPlace pyproject.toml \
      --replace-fail 'oscrypto = { git = "https://github.com/wbond/oscrypto.git", rev = "1547f535001ba568b239b8797465536759c742a3" }' 'oscrypto = "*"' \
      --replace-fail 'certvalidator = { git = "https://github.com/achow101/certvalidator.git", rev = "e5bdb4bfcaa09fa0af355eb8867d00dfeecba08c" }' 'certvalidator = "*"' \
      --replace-fail 'elf-esteem = { git = "https://github.com/LRGH/elfesteem.git", rev = "5800fcf150dec3ce524f14bc2f24dc037f4826e6" }' 'elf-esteem = "*"'
  '';

  dependencies = [
    python3Packages.asn1crypto
    python3Packages.oscrypto
    certvalidator # the achow101 fork (above), not nixpkgs' stock
    elfesteem
  ];

  pythonRelaxDeps = true;
  dontCheckRuntimeDeps = true;
  doCheck = false;

  meta = {
    description = "Mach-O binary signature tool (pinned to Bitcoin Core GUIX manifest)";
    homepage = "https://github.com/achow101/signapple";
    license = lib.licenses.mit;
    mainProgram = "signapple";
  };
}

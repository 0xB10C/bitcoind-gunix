{ runCommandLocal, coreutils, gnused, diffutils }:
{ name, files, expected ? null }:
runCommandLocal name
{
  nativeBuildInputs = [ coreutils gnused diffutils ];
} ''
  # `files` is given in the exact order of upstream's published
  # SHA256SUMS (see default.nix) -- sha256sum preserves argv order, so no
  # re-sort here (a basename sort would reorder e.g. win64 relative to
  # x86_64-linux-gnu, since upstream's order comes from the pre-basename
  # HOST directory path, not the published filename).
  sha256sum ${toString files} \
    | sed -E \
        -e 's@(^[0-9a-f]{64}[[:space:]]+).*/@\1@' \
        -e 's@^([0-9a-f]{64}[[:space:]]+)[0-9a-z]{32}-@\1@' \
    > "$out"

  ${if expected == null then ''
    echo "BUILT (no upstream file): ${name}"
  '' else ''
    # The whole file, order included, has to equal the checked-in
    # guix.sigs attestation.
    if ! diff -u ${expected} "$out"; then
      echo "FAIL: ${name} differs from the checked-in guix.sigs file"
      exit 1
    fi
    echo "OK: ${name} matches the checked-in guix.sigs file"
  ''}
  cat "$out"
''

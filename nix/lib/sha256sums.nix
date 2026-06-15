{ runCommandLocal, coreutils, gnused }:
{ name, files }:
runCommandLocal name
{
  nativeBuildInputs = [ coreutils gnused ];
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
''

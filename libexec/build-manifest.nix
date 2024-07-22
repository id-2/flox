{
  pkgs ? import <nixpkgs> {},
  name,
  flox-env,
  install-prefix,
}: let
  flox-env-package = builtins.storePath flox-env;
  install-prefix-contents = /. + install-prefix;
in
  pkgs.runCommand name {
    buildInputs = with pkgs; [flox-env-package gnutar gnused makeWrapper];
  } ''
    mkdir $out
    tar -C ${install-prefix-contents} -c --mode=u+w -f - . | \
      sed --binary "s%${install-prefix}%$out%g" | \
      tar -C $out -xvvf -
    # Wrap contents of files in bin with ${flox-env-package}/activate
    for prog in $out/bin/* $out/sbin/*; do
      assertExecutable "$prog"
      hidden="$(dirname "$prog")/.$(basename "$prog")"-wrapped
      mv "$prog" "$hidden"
      makeShellWrapper "${flox-env-package}/activate" "$prog" \
        --inherit-argv0 \
        --set FLOX_ENV "${flox-env-package}" \
        --add-flags "$hidden"
    done
  ''

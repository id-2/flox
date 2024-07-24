{
  pkgs ? import <nixpkgs> {},
  name,
  flox-env,
  install-prefix,
  srcdir ? null, # optional
  build-script ? null, # optional
}: let
  flox-env-package = builtins.storePath flox-env;
  install-prefix-contents = /. + install-prefix;
  src =
    if (srcdir == null)
    then null
    else builtins.fetchGit srcdir;
in
  pkgs.runCommand name {
    inherit src;
    buildInputs = with pkgs; [flox-env-package gnutar gnused makeWrapper];
  } (
    ''
      set -x
      mkdir -p $out
    ''
    + (
      if (build-script == null)
      then ''
               # If no build script is provided copy the contents of install prefix
        # to the output directory, rewriting path references as we go.
               tar -C ${install-prefix-contents} -c --mode=u+w -f - . | \
                 sed --binary "s%${install-prefix}%$out%g" | \
                 tar -C $out -xvvf -
      ''
      else ''
               # If the build script is provided, then it's expected that we will
        # invoke it from within the sandbox to write directly to $out. The
        # choice of pure or impure mode occurs outside of this script as
        # the derivation is instantiated.
               source $stdenv/setup
               unpackPhase
        cd "$sourceRoot"
               FLOX_TURBO=1 ${flox-env-package}/activate bash ${builtins.storePath build-script}
      ''
    )
    + ''
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
  )

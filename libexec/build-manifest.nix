{
  pkgs ? import <nixpkgs> {},
  name,
  flox-env,
  install-prefix,
  __impure ? false,
  srcdir ? null, # optional
  build-script ? null, # optional
}: let
  flox-env-package = builtins.storePath flox-env;
  install-prefix-contents = /. + install-prefix;
  src =
    if (srcdir == null)
    then null
    else builtins.fetchGit srcdir;
  build-script-contents = /. + build-script;
in
  pkgs.runCommand name {
    inherit __impure src;
    buildInputs = with pkgs; [flox-env-package gnutar gnused makeWrapper];
  } (
    ''
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
        export NIX_ENFORCE_PURITY=${if __impure then "0" else "1"}
        source $stdenv/setup
        unpackPhase
        cd "$sourceRoot"
        FLOX_TURBO=1 ${flox-env-package}/activate bash ${build-script-contents}
      ''
    )
    + ''
      # Wrap contents of files in bin with ${flox-env-package}/activate
      set -x
      for prog in $out/bin/* $out/sbin/*; do
	if [ -L "$prog" ]; then
	  : # You cannot wrap a symlink, so just leave it be?
        else
          assertExecutable "$prog"
          hidden="$(dirname "$prog")/.$(basename "$prog")"-wrapped
          mv "$prog" "$hidden"
          makeShellWrapper "${flox-env-package}/activate" "$prog" \
            --inherit-argv0 \
            --set FLOX_ENV "${flox-env-package}" \
            --add-flags "$hidden"
        fi
      done
    ''
  )

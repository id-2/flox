{
  pkgs ? import <nixpkgs> {},
  name,
  flox-env,
  install-prefix,
  __impure ? false,
  srcdir ? null, # optional
  buildScript ? null, # optional
  buildCache ? null, # optional
}:

# First a few assertions to ensure that the inputs are consistent.

# buildCache is only meaningful with a build script
assert (buildCache != null) -> (buildScript != null);
# __impure is only set with a build script
assert __impure -> (buildScript != null);
# srcdir is only required with a build script
assert (srcdir != null) -> (buildScript != null);

let

  flox-env-package = builtins.storePath flox-env;
  install-prefix-contents = /. + install-prefix;
  src =
    if (srcdir == null)
    then null
    else builtins.fetchGit srcdir;
  buildScript-contents = /. + buildScript;
  buildCache-tgz = if buildCache == "" then null else (/. + buildCache);

in
  pkgs.runCommand name {
    inherit __impure src;
    buildInputs = with pkgs; [flox-env-package gnutar gnused makeWrapper];
    outputs = [ "out" ] ++ pkgs.lib.optionals ( buildCache != null ) [ "buildCache" ];
  } (
    ''
      mkdir -p $out
    ''
    + (
      if (buildScript == null)
      then ''
        # If no build script is provided copy the contents of install prefix
        # to the output directory, rewriting path references as we go.
        tar -C ${install-prefix-contents} -c --mode=u+w -f - . | \
          sed --binary "s%${install-prefix}%$out%g" | \
          tar -C $out -xf -
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
	# Extract contents of the cache, if it exists.
        ${ if buildCache-tgz == null then ":" else
          "tar --skip-old-files -xzf ${buildCache-tgz}" }
        ${ if buildCache == null then ''
          # When not preserving a cache we just run the build normally.
          FLOX_TURBO=1 ${flox-env-package}/activate bash ${buildScript-contents}
        '' else ''
          # If the build fails we still want to preserve the build cache, so we
          # remove $out on failure and allow the Nix build to proceed to write
          # the result symlink.
          FLOX_TURBO=1 ${flox-env-package}/activate bash ${buildScript-contents} || \
            ( rm -rf $out && echo "flox build failed (caching build dir)" | tee $out 1>&2 )
        '' }
      ''
    )
    + ''
      # Wrap contents of files in bin with ${flox-env-package}/activate
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
    '' + pkgs.lib.optionalString (buildCache != null) ''
      tar -czf $buildCache .
    ''
  )

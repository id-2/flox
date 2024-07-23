# Abort on all non-zero exit codes.
set -e

# Assert script has been called with $FLOX_ENV set.
[ -n "$FLOX_ENV" ] || {
  echo "ERROR: FLOX_ENV must be set to the path of the flox environment." 1>&2
  exit 1
}

# Builds are expected to be performed from the same directory, so for now
# change directory to top of git repo for all builds.
# TODO: implement some way of overriding topdir on a build-specific basis.
cd "$(git rev-parse --show-toplevel)"

function build() {
  script="$1"

  # Infer pname from script path.
  pname="$(basename "$script")"

  # Eventually derive version somehow, but hardcode it in the meantime.
  version="0.0.0"

  # Calculate name.
  name="$pname-$version"

  # Set temp path of same strlen as eventual package storePath using sha256sum
  # derived from both the current working directory and the $FLOX_ENV package
  # to provide a stable random seed to avoid collisions.
  tmphash="$( ( pwd && realpath "$FLOX_ENV" ) | sha256sum | head -c32)"
  export out="/tmp/store_$tmphash-$name"

  # Perform build script with activated environment, using FLOX_TURBO to
  # skip any profile hook initializations.
  FLOX_TURBO=1 "$FLOX_ENV/activate" bash "$script"

  # Create new env layering results of build script with original env.
  # Note: read name from manifest.toml (includes version)
  nix --extra-experimental-features nix-command \
    build -L --file __FLOX_CLI_OUTPATH__/libexec/build-manifest.nix \
      --argstr name "$name" \
      --argstr flox-env "$FLOX_ENV" \
      --argstr install-prefix "$out" \
      --out-link "result-$pname" \
      --offline
}

# Build list of packages to be built either from argv or as the
# set of all packages found in $FLOX_ENV/package-builds.d.
declare -a packages=()
if [ $# -gt 0 ]; then
  while test $# -gt 0; do
    if [ -f "$FLOX_ENV/package-builds.d/$1" ]; then
      packages+=("$FLOX_ENV/package-builds.d/$1")
      shift
    else
      echo "ERROR: $1 is not a valid package." 1>&2
      exit 1
    fi
  done
else
  if [ -d "$FLOX_ENV/package-builds.d" ]; then
    if [ -z "$(ls "$FLOX_ENV/package-builds.d")" ]; then
      echo "ERROR: No packages found in $FLOX_ENV/package-builds.d." 1>&2
      exit 1
    fi
    packages=("$FLOX_ENV/package-builds.d"/*)
  else
    echo "ERROR: No packages found in $FLOX_ENV/package-builds.d." 1>&2
    exit 1
  fi
fi

# Build each package in the list.
# TODO: parallelize this in the rust version.
if [ ${#packages[@]} -gt 0 ]; then
  for package in "${packages[@]}"; do
    build "$package"
  done
else
  echo "No packages to build."
fi

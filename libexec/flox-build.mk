#
# This makefile implements Tom's stepladder from manifest to Nix builds:
#
# 1. "manifest": sets $out in the environment, invokes the build commands in a subshell
#    (using bash), then turns the $out directory into a Nix package with all outpath
#    references replaced with the real $out and all bin/* commands wrapped with
#    $FLOX_ENV/activate
# 2. "impure manifest": does the same, except the script is invoked from within the runCommand
#    builder in "impure" mode with full network and filesystem access but with a fake home directory
#    --> identify accidental dependencies on home dir, filesystems
# 3. "pure manifest": does the same, except within a "pure" build with no access to the network
#    or filesystem
#    --> identify accidental dependencies on network
# 4. "staged manifest": splits the builds into stages, each of which can be either fingerprinted
#    impure or pure as required for the build
#    --> introduces idea of fixed output derivation (impure build w/ fingerprint)
#

# Start by checking that the FLOX_ENV environment variable is set.
ifeq (,$(FLOX_ENV))
  $(error ERROR: FLOX_ENV not defined)
endif

# Set the default goal to be all builds if one is not specified.
.DEFAULT_GOAL := all

# Use the wildcard operator to identify targets in the provided $FLOX_ENV.
BUILDS := $(wildcard $(FLOX_ENV)/package-builds.d/*)

# The following template renders targets for each of the build modes.
# We render all the possible build modes here and then below we select
# the actual targets to be evaluated based on the build types observed.
define BUILD_template =
  # Infer pname from script path.
  $(eval _pname = $(notdir $(build)))
  # Target names cannot have "-" in them so replace with "_" in the target name.
  $(eval _target = $(subst -,_,$(_pname)))
  # Eventually derive version somehow, but hardcode it in the meantime.
  $(eval _version = 0.0.0)
  # Calculate name.
  $(eval _name = $(_pname)-$(_version))

  # Set temp outpath of same strlen as eventual package storePath using sha256sum
  # derived from the package name, the current working directory and the $(FLOX_ENV)
  # package to provide a stable random seed to avoid collisions.
  $(eval _tmphash = $(shell ( \
    echo $(_name) && pwd && realpath "$$FLOX_ENV") | sha256sum | head -c32))
  $(eval _out = /tmp/store_$(_tmphash)-$(_name))

  # It is expected that the build mode will be specified on a per-build basis
  # within the manifest, but in the meantime while we wait for the manifest
  # parser to be implemented we will grep for an explicit BUILD_MODE setting
  # within the build script. If one is not found, we will default to "manifest"
  $(eval _build_mode_grep = $(shell grep -E 'BUILD_MODE=(pure|impure|manifest)$$' $(build) | head -1 | cut -d= -f2))
  $(eval _build_mode = $(if $(_build_mode_grep),$(_build_mode_grep),manifest))

  # Render the build script with the package prerequisites replaced with their
  # corresponding outpaths.
  $(eval $(_target)_build_script := $(shell mktemp --dry-run --suffix=-build-$(_pname).bash))

  # By the time this rule will be evaluated all of the package dependencies
  # will have been added to the set of rule prerequisites in $^, using their
  # "safe" name (with "-" characters replaced with "_"), and these targets
  # will have successfully built the corresponding result-$(_pname) symlinks.
  # Iterate through this list, replacing all instances of "${package}" with the
  # corresponding storePath as identified by the result-* symlink.
  .INTERMEDIATE: $($(_target)_build_script)
  $($(_target)_build_script): $(build)
	@echo "Rendering $(_pname) build script to $$@"
	@cp $$< $$@
	@for i in $$^; do \
	  if [ -L "$$$$i" ]; then \
	    outpath="$$$$(readlink $$$$i)"; \
	    if [ -n "$$$$outpath" ]; then \
	      pkgname="$$$$(echo $$$$i | cut -d- -f2-)"; \
	      sed -i "s%\$$$${$$$$pkgname}%$$$$outpath%g" $$@; \
	    fi; \
	  fi; \
	done

  # Type 1 "manifest" build
  .INTERMEDIATE: $(_target)_manifest
  $(_target)_manifest: $($(_target)_build_script)
	@echo "Building $(_name) in manifest mode"
	FLOX_TURBO=1 out=$(_out) $(FLOX_ENV)/activate bash $$<
	nix --extra-experimental-features nix-command \
	  build -L --file __FLOX_CLI_OUTPATH__/libexec/build-manifest.nix \
	    --argstr name "$(_name)" \
	    --argstr flox-env "$(FLOX_ENV)" \
	    --argstr install-prefix "$(_out)" \
	    --out-link "result-$(_pname)" \
	    --offline

  # Type 2 "impure" build
  .INTERMEDIATE: $(_target)_impure
  $(_target)_impure: $($(_target)_build_script)
	@echo "Building $(_name) in impure mode"
	@# First verify that the {ca,impure}-derivations features are enabled.
	@nix --extra-experimental-features nix-command \
	  show-config experimental-features | grep -q ca-derivations || \
	    (echo "ERROR: ca-derivations feature not enabled" 1>&2; exit 1)
	@nix --extra-experimental-features nix-command \
	  show-config experimental-features | grep -q impure-derivations || \
	    (echo "ERROR: impure-derivations feature not enabled" 1>&2; exit 1)
	nix --extra-experimental-features "nix-command impure-derivations" \
	  build -L --file __FLOX_CLI_OUTPATH__/libexec/build-manifest.nix \
	    --argstr name "$(_name)" \
	    --argstr srcdir "$(realpath .)" \
	    --argstr flox-env "$(FLOX_ENV)" \
	    --argstr install-prefix "$(_out)" \
	    --argstr build-script "$$<" \
	    --out-link "result-$(_pname)" \
	    --arg __impure true \
	    --impure

  # Type 3 "pure" build
  .INTERMEDIATE: $(_target)_pure
  $(_target)_pure: $($(_target)_build_script)
	@echo "Building $(_name) in pure mode"
	nix --extra-experimental-features nix-command \
	  build -L --file __FLOX_CLI_OUTPATH__/libexec/build-manifest.nix \
	    --argstr name "$(_name)" \
	    --argstr srcdir "$(realpath .)" \
	    --argstr flox-env "$(FLOX_ENV)" \
	    --argstr install-prefix "$(_out)" \
	    --argstr build-script "$$<" \
	    --out-link "result-$(_pname)"

  # Select the desired build mode as we declare the result symlink target.
  result-$(_pname): $(_target)_$(_build_mode)

  # Create a helper target for referring to the package by its name rather
  # than the [real] result symlink we're looking to create.
  $(_pname): result-$(_pname)

  # Accumulate a list of known build targets for the "all" target.
  all += $(_pname)
endef

$(foreach build,$(BUILDS),$(eval $(call BUILD_template)))

# We then scan for "${package}" references within the build instructions and
# add target prerequisites for any inter-package prerequisites, letting make
# flag any circular dependencies encountered along the way.
define DEPENDS_template =
  # Infer pname from script path.
  $(eval _pname = $(notdir $(build)))
  # Target names cannot have "-" in them so replace with "_" in the target name.
  $(eval _target = $(subst -,_,$(_pname)))
  # Look for references to ${package} in the build script, and if found add
  # dependency from the target to the package.
  $(if $(shell grep '\$${$(package)}' $(build)),\
    $(eval _dep = result-$(package))\
    $($(_target)_build_script): $(_dep))
endef

# Iterate over each possible {package,package} pair looking for dependencies,
# being careful to avoid looking for references to the package in its own build.
$(foreach build,$(BUILDS),\
  $(foreach package,$(notdir $(BUILDS)),\
    $(if $(filter-out $(package),$(notdir $(build))),\
      $(eval $(call DEPENDS_template)))))

# Finally, we create the "all" target to build all known packages.
all: $(all)

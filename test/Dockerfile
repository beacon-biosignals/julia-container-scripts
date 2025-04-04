ARG JULIA_VERSION=1.11.0
FROM julia:${JULIA_VERSION}-bookworm AS julia-base

# Update `JULIA_CPU_TARGET` from the default of `native` to something more generic for 
# improved compatibility. For example building an image on an Intel x86_64 CPU with
# `native` the compiled Julia code could use AVX instructions which would fail to execute
# when running on an AMD CPU.
#
# Using the same generic CPU targets as used by official Julia builds for Linux:
# https://github.com/JuliaCI/julia-buildkite/blob/e24608c9023e165c9bedbe5358fabe20016b56b7/utilities/build_envs.sh#L20-L94
# https://docs.julialang.org/en/v1/devdocs/sysimg/#Specifying-multiple-system-image-targets
FROM julia-base AS julia-amd64
ENV JULIA_CPU_TARGET="generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1);x86-64-v4,-rdrnd,base(1)"

FROM julia-base AS julia-arm64
ENV JULIA_CPU_TARGET="generic;cortex-a57;thunderx2t99;carmel,clone_all;apple-m1,base(3);neoverse-512tvb,base(3)"

# https://docs.docker.com/reference/dockerfile/#automatic-platform-args-in-the-global-scope
FROM julia-${TARGETARCH} AS julia

# Follow Docker best practises by running the container as a non-root user
# https://docs.docker.com/build/building/best-practices/#user
ENV USER="docker"
ENV GROUP=${USER}

ENV UID="1000"
ENV GID=${UID}

RUN addgroup --gid ${GID} ${GROUP} && \
    adduser --uid ${UID} --ingroup ${GROUP} --shell /bin/sh --disabled-password --gecos "" ${USER}

ENV JULIA_DEPOT_PATH="/usr/local/share/julia-depot:"

# Disable logging scratch usage which is problematic in read-only environments.
# https://github.com/JuliaPackaging/Scratch.jl#can-i-disable-logging-scratch-usage
ENV JULIA_SCRATCH_TRACK_ACCESS="0"

# Disable Julia history on read-only filesystems
ENV JULIA_HISTORY="/dev/null"

# Disable automatic package precompilation. We'll control when packages are precompiled.
ENV JULIA_PKG_PRECOMPILE_AUTO="0"

# Add all registries for instantiation.
RUN julia --color=yes -e 'using Pkg; Pkg.Registry.add("General")'

# Limit Docker layer invalidation by only copying the Project.toml/Manifest.toml files.
ARG JULIA_PROJECT="/project"
ENV JULIA_PROJECT="${JULIA_PROJECT}"
COPY Project.toml Manifest.toml ${JULIA_PROJECT}/

# Instantiate the Julia project environment and avoid precompiling. Ensure we perform a
# registry update here as changes to the Project.toml/Manifest.toml does not invalidate the
# Docker layer which added the registry.
RUN julia --color=yes -e 'using Pkg; Pkg.Registry.update(); Pkg.resolve(); Pkg.instantiate(); Pkg.build()'

# Allow passing in a unique cache mount ID to support build concurrency.
ARG JULIA_DEPOT_CACHE_ID="julia-depot"
ARG JULIA_DEPOT_CACHE_TARGET="/mnt/julia-depot"

# Pass in a random string as a build-arg to force precompilation to run on every Docker
# build (e.g. `--build-arg=INVALIDATE_PRECOMPILE=$(openssl rand -hex 20)`).
ARG INVALIDATE_PRECOMPILE=""
RUN echo "$INVALIDATE_PRECOMPILE"

COPY pkg-precompile.jl /usr/local/bin
RUN --mount=type=cache,id=${JULIA_DEPOT_CACHE_ID},sharing=shared,target=${JULIA_DEPOT_CACHE_TARGET} \
    # curl -fsSL https://raw.githubusercontent.com/beacon-biosignals/julia-container-scripts/refs/tags/v1/pkg-precompile.jl | JULIA_DEBUG=pkg-precompile julia
    JULIA_DEBUG=pkg-precompile pkg-precompile.jl "${JULIA_DEPOT_CACHE_TARGET}" && \
    find "${JULIA_DEPOT_CACHE_TARGET}" -name "*.ji" -type f | sort

FROM julia AS relocate-depot

# In Julia versions before 1.11 moving the depot would result in precompilation files being invalidated
ENV JULIA_DEPOT_PATH="/usr/local/share/julia-depot-alt:"
RUN mv /usr/local/share/julia-depot /usr/local/share/julia-depot-alt

FROM julia AS user

USER ${USER}

# Ensure the user can successfully load all Julia direct dependencies. Failures here are
# typically due to the package's `__init__` function attempting to write content into the
# Julia depot.
#
# Purposefully avoiding using `Pkg.dependencies` as that function attempts to create a
# `DEPOT/logs/manifest_usage.toml.pid` which fails as the user doesn't have write access to
# the Julia depot.
# RUN julia -e ' \
#         using TOML; \
#         for direct_dep_name in keys(TOML.parsefile(Base.active_project())["deps"]) \
#             Base.require(Main, Symbol(direct_dep_name)); \
#         end;'

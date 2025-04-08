# julia-container-scripts

Provides useful scripts for creating Julia container images.

## `pkg-precompile.jl`

The `pkg-precompile.jl` script supports creating Julia precompilation cache (`.ji`) files in a [build container cache mount](https://docs.docker.com/reference/dockerfile/#run---mounttypecache). By utilizing the build cache mount we can reuse precompilation files between builds which signficantly improves reduces Docker build times. A complete `Dockerfile` example can be seen below:

```Dockerfile
ARG JULIA_VERSION=1.11.4
FROM julia:${JULIA_VERSION}-bookworm AS julia-base

# Disable automatic package precompilation. We'll control when packages are precompiled.
ENV JULIA_PKG_PRECOMPILE_AUTO="0"

# Add registries required for instantiation
RUN julia --color=yes -e 'using Pkg; Pkg.Registry.add("General")'

# Limit Docker layer invalidation by only copying the Project.toml/Manifest.toml files.
ENV JULIA_PROJECT="/project"
COPY Project.toml *Manifest.toml ${JULIA_PROJECT}/

# TODO: Delete this optional statement if your Project.toml does not include the field "name".
#
# Julia 1.10.0 - 1.10.6 and 1.11.0 require this source file to be present when
# instantiating a named Julia project.
RUN mkdir -p "${JULIA_PROJECT}/src" && \
    touch "${JULIA_PROJECT}/src/$(basename "${JULIA_PROJECT}").jl"

# Instantiate the Julia project environment and avoid precompiling. Ensure we perform a
# registry update here as changes to the Project.toml/Manifest.toml does not invalidate the
# Docker layer which added the registry.
RUN julia --color=yes -e 'using Pkg; Pkg.Registry.update(); Pkg.instantiate(); Pkg.build()'

# Instantiate the Julia project environment and avoid precompiling. Ensure we perform a
# registry update here as changes to the Project.toml/Manifest.toml does not invalidate the
# Docker layer which added the registry.
RUN julia --color=yes -e 'using Pkg; Pkg.Registry.update(); Pkg.instantiate(); Pkg.build()'

# TODO: Delete this optional statement if you don't care about Julia 1.10 support.
# Typically, this statement is combined with instantiation above.
#
# Use a fixed modification time for all files in "packages" to avoid unnecessary precompile
# cache invalidation on Julia 1.10.
RUN julia -e 'VERSION < v"1.11" || exit(1)' && \
    find "$(julia -e 'println(DEPOT_PATH[1])')/packages" -exec touch -m -t 197001010000 {} \;

# Precompile project dependencies using a Docker cache mount which persists between builds.
RUN --mount=type=cache,id=julia-depot,sharing=shared,target=/mnt/julia-depot \
    curl -fsSL https://raw.githubusercontent.com/beacon-biosignals/julia-container-scripts/refs/tags/v1/pkg-precompile.jl &&
    install pkg-precompile.jl /usr/local/bin && \
    pkg-precompile.jl "/mnt/julia-depot" && \

# Copy files necessary to load package and perform the first initialization.
COPY src ${JULIA_PROJECT}/src
RUN julia -e 'using Pkg; Pkg.precompile(ARGS[1]; timing=true); Base.require(Main, Symbol(ARGS[1]))' $(basename "${JULIA_PROJECT}")
```

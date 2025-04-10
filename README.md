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

# TODO: Delete this optional statement if your Project.toml does not include the field
# "name" or you don't care about supporting the Julia versions listed below.
#
# Julia 1.10.0 - 1.10.6 and 1.11.0 require this source file to be present when
# instantiating a named Julia project.
RUN curl -fsSLO https://raw.githubusercontent.com/beacon-biosignals/julia-container-scripts/refs/tags/v0.1/gen-pkg-src.jl && \
    chmod +x gen-pkg-src.jl && \
    ./gen-pkg-src.jl && \
    rm gen-pkg-src.jl

# Instantiate the Julia project environment and avoid precompiling. Ensure we perform a
# registry update here as changes to the Project.toml/Manifest.toml do not invalidate the
# Docker layer which added the registry.
RUN julia --color=yes -e 'using Pkg; Pkg.Registry.update(); Pkg.instantiate(); Pkg.build()'

# TODO: Delete this optional statement if you don't care about Julia 1.10 support or combine
# this statement with instantiate above to avoid bloating image size.
#
# Use a fixed modification time for all files in "packages" to avoid unnecessary precompile
# cache invalidation on Julia 1.10.
RUN julia -e 'VERSION < v"1.11" || exit(1)' && \
    find "$(julia -e 'println(DEPOT_PATH[1])')/packages" -exec touch -m -t 197001010000 {} \;

# Precompile project dependencies using a Docker cache mount which persists between builds.
RUN --mount=type=cache,id=julia-depot,sharing=shared,target=/mnt/julia-depot \
    curl -fsSLO https://raw.githubusercontent.com/beacon-biosignals/julia-container-scripts/refs/tags/v0.1/pkg-precompile.jl && \
    chmod +x pkg-precompile.jl && \
    ./pkg-precompile.jl "/mnt/julia-depot" && \
    rm pkg-precompile.jl

# Copy files necessary to load package and perform the first initialization.
COPY src ${JULIA_PROJECT}/src
RUN julia -e 'using Pkg; name = Pkg.Types.EnvCache().project.name; Pkg.precompile(name; timing=true); Base.require(Main, Symbol(name))'
```

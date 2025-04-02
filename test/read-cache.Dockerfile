FROM debian:bookworm

ARG JULIA_DEPOT_CACHE_ID="julia-depot"
ARG JULIA_DEPOT_CACHE_TARGET="/mnt/julia-depot"

# Pass in a random string as a build-arg to force precompilation to run on every Docker
# build (e.g. `--build-arg=INVALIDATE_READ_CACHE=$(openssl rand -hex 20)`).
ARG INVALIDATE_READ_CACHE=""
RUN echo "$INVALIDATE_READ_CACHE"

RUN --mount=type=cache,id=${JULIA_DEPOT_CACHE_ID},sharing=shared,target=${JULIA_DEPOT_CACHE_TARGET} \
    find ${JULIA_DEPOT_CACHE_TARGET} -type f | tee /inventory.txt

ENTRYPOINT ["/bin/bash", "-c", "cat /inventory.txt"]
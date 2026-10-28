ARG TAG=dev

FROM mongo:8.0 AS mongo-tools

FROM ghcr.io/openfoodfacts/search-a-licious/search_service_image:${TAG}

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        gzip \
        jq \
        util-linux \
    && rm -rf /var/lib/apt/lists/*

COPY --from=mongo-tools /usr/bin/mongorestore /usr/local/bin/mongorestore
COPY --from=mongo-tools /usr/bin/mongoimport /usr/local/bin/mongoimport
COPY --from=mongo-tools /usr/bin/mongoexport /usr/local/bin/mongoexport

COPY --chown=off:off scripts/off-sync /opt/off-sync
RUN chmod +x /opt/off-sync/full-rebuild.sh /opt/off-sync/sync-deltas.sh

USER off:off

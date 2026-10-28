ARG TAG=dev

FROM mongo:8.0 AS mongo-tools

FROM ghcr.io/openfoodfacts/search-a-licious/search_service_image:${TAG}

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gzip \
        jq \
        util-linux \
    && rm -rf /var/lib/apt/lists/*

COPY --from=mongo-tools /usr/bin/mongorestore /usr/local/bin/mongorestore
COPY --from=mongo-tools /usr/bin/mongoimport /usr/local/bin/mongoimport
COPY --from=mongo-tools /usr/bin/mongoexport /usr/local/bin/mongoexport

USER 1000:1000

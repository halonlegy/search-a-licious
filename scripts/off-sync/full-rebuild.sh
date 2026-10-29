#!/usr/bin/env bash

set -Eeuo pipefail

DATA_DIR="${OFF_SYNC_DATA_DIR:-/opt/search/data/off-sync}"
LOCK_FILE="${DATA_DIR}/sync.lock"
DUMP_PATH="${DATA_DIR}/openfoodfacts-mongodbdump.gz"
DUMP_TMP="${DUMP_PATH}.part"
JSONL_PATH="${DATA_DIR}/openfoodfacts-mongodb-products.jsonl.gz"
JSONL_TMP="${JSONL_PATH}.tmp"
COUNT_FILE="${DATA_DIR}/product-count.tmp"
MONGO_URI="${MONGO_URI:-mongodb://mongo:27017}"
DUMP_URL="${OFF_MONGO_DUMP_URL:-https://static.openfoodfacts.org/data/openfoodfacts-mongodbdump.gz}"
MIN_PRODUCTS="${OFF_SYNC_MIN_PRODUCTS:-10000000}"
IMPORT_PROCESSES="${OFF_SYNC_IMPORT_PROCESSES:-4}"
ES_URL="${ELASTICSEARCH_URL:-http://es01:9200}"
ES_ALIAS="${OFF_SYNC_ES_ALIAS:-openfoodfacts}"
CLEANUP_INDEXES="${OFF_SYNC_CLEANUP_INDEXES:-false}"
RESUME_FROM_EXPORT="${OFF_SYNC_RESUME_FROM_EXPORT:-false}"

log() {
  printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"
}

alias_target() {
  curl --fail --silent --show-error "${ES_URL}/_alias/${ES_ALIAS}" \
    | jq --raw-output 'keys[0] // empty'
}

mkdir -p "${DATA_DIR}"
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  log "Another OFF synchronization is already running; exiting."
  exit 0
fi

if [[ "${RESUME_FROM_EXPORT}" == "true" ]]; then
  log "Resuming the full rebuild from the MongoDB-to-JSONL export."
else
  log "Downloading the full Open Food Facts MongoDB dump."
  dump_last_modified="$(
    curl --fail --location --silent --show-error --head "${DUMP_URL}" \
      | awk 'tolower($0) ~ /^last-modified:/ { sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); value=$0 } END { print value }'
  )"
  if [[ -z "${dump_last_modified}" ]]; then
    log "The MongoDB dump response did not contain a Last-Modified header."
    exit 1
  fi
  dump_timestamp="$(date --date="${dump_last_modified}" +%s)"

  if ! gzip --test < "${DUMP_TMP}" 2>/dev/null; then
    curl --fail --location --show-error \
      --retry 5 --retry-all-errors --continue-at - \
      --output "${DUMP_TMP}" \
      "${DUMP_URL}"
  fi
  gzip --test < "${DUMP_TMP}"
  mv "${DUMP_TMP}" "${DUMP_PATH}"

  log "Replacing the local off.products collection from the full dump."
  mongorestore \
    --uri="${MONGO_URI}" \
    --gzip \
    --archive="${DUMP_PATH}" \
    --nsInclude=off.products \
    --drop \
    --noIndexRestore

  log "Applying every currently available delta after the full snapshot."
  OFF_SYNC_LOCK_HELD=true \
  OFF_SYNC_FORCE_ALL=true \
  OFF_SYNC_SKIP_ES_IMPORT=true \
  OFF_SYNC_MIN_DELTA_END="${dump_timestamp}" \
    /opt/off-sync/sync-deltas.sh
fi

reuse_export=false
if [[ "${RESUME_FROM_EXPORT}" == "true" && -s "${JSONL_TMP}" && -s "${COUNT_FILE}" ]] \
  && gzip --test < "${JSONL_TMP}" 2>/dev/null; then
  reuse_export=true
  log "Reusing the completed MongoDB JSONL export."
fi

if [[ "${reuse_export}" != "true" ]]; then
  log "Exporting MongoDB products to Search-a-licious JSONL."
  rm -f "${COUNT_FILE}" "${JSONL_TMP}"
  mongoexport \
    --quiet \
    --uri="${MONGO_URI}" \
    --db=off \
    --collection=products \
    --type=json \
    --jsonFormat=relaxed \
    | jq --compact-output '
        select(.code != null and .code != "")
        | .code = (.code | tostring)
        | .obsolete = (.obsolete // false)
        | del(._id)
      ' \
    | awk -v count_file="${COUNT_FILE}" '
        { print; count++ }
        END { print count + 0 > count_file }
      ' \
    | gzip --stdout \
    > "${JSONL_TMP}"

  gzip --test < "${JSONL_TMP}"
fi

product_count="$(<"${COUNT_FILE}")"
if (( product_count < MIN_PRODUCTS )); then
  log "Refusing import: only ${product_count} products were exported; minimum is ${MIN_PRODUCTS}."
  exit 1
fi
mv "${JSONL_TMP}" "${JSONL_PATH}"
rm -f "${COUNT_FILE}"

before_index="$(alias_target || true)"
log "Starting full Elasticsearch import of ${product_count} products; current index is ${before_index:-none}."
set +e
python3 -m app import "${JSONL_PATH}" \
  --skip-updates \
  --num-processes "${IMPORT_PROCESSES}"
import_status=$?
set -e

after_index="$(alias_target)"
indexed_count="$(curl --fail --silent --show-error "${ES_URL}/${ES_ALIAS}/_count" | jq '.count')"

if [[ -z "${after_index}" || "${after_index}" == "${before_index}" ]]; then
  log "The Elasticsearch alias was not switched to a newly built index."
  exit 1
fi
if (( indexed_count < MIN_PRODUCTS )); then
  log "The new Elasticsearch index has only ${indexed_count} documents."
  exit 1
fi

if (( import_status != 0 )); then
  log "WARNING: Search-a-licious reported document errors, but switched the alias successfully."
fi
log "Elasticsearch now uses ${after_index} with ${indexed_count} documents."

if [[ "${CLEANUP_INDEXES}" == "true" ]]; then
  log "Removing inactive Elasticsearch indexes."
  python3 -m app cleanup-indexes
fi

log "Full rebuild completed successfully."

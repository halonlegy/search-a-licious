#!/usr/bin/env bash

set -Eeuo pipefail

DATA_DIR="${OFF_SYNC_DATA_DIR:-/opt/search/data/off-sync}"
DELTA_DIR="${DATA_DIR}/deltas"
STATE_FILE="${DATA_DIR}/last-delta"
LOCK_FILE="${DATA_DIR}/sync.lock"
INDEX_FILE="${DATA_DIR}/delta-index.txt"
MONGO_URI="${MONGO_URI:-mongodb://mongo:27017}"
DELTA_INDEX_URL="${OFF_DELTA_INDEX_URL:-https://static.openfoodfacts.org/data/delta/index.txt}"
DELTA_BASE_URL="${DELTA_INDEX_URL%/index.txt}"
IMPORT_PROCESSES="${OFF_SYNC_IMPORT_PROCESSES:-4}"
FORCE_ALL="${OFF_SYNC_FORCE_ALL:-false}"
SKIP_ES="${OFF_SYNC_SKIP_ES_IMPORT:-false}"
MIN_DELTA_END="${OFF_SYNC_MIN_DELTA_END:-0}"

log() {
  printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"
}

mkdir -p "${DELTA_DIR}"

if [[ "${OFF_SYNC_LOCK_HELD:-false}" != "true" ]]; then
  exec 9>"${LOCK_FILE}"
  if ! flock -n 9; then
    log "Another OFF synchronization is already running; exiting."
    exit 0
  fi
fi

index_tmp="${INDEX_FILE}.tmp"
curl --fail --location --silent --show-error \
  --retry 5 --retry-all-errors \
  "${DELTA_INDEX_URL}" \
  | tr '[:space:]' '\n' \
  | sed '/^$/d' \
  | awk '/^openfoodfacts_products_[0-9]+_[0-9]+\.json\.gz$/' \
  | sort -t_ -k3,3n -k4,4n \
  > "${index_tmp}"

if [[ ! -s "${index_tmp}" ]]; then
  log "The OFF delta index is empty or has an unexpected format."
  exit 1
fi
mv "${index_tmp}" "${INDEX_FILE}"

last_delta=""
if [[ -s "${STATE_FILE}" ]]; then
  last_delta="$(<"${STATE_FILE}")"
fi

if [[ "${FORCE_ALL}" != "true" && -n "${last_delta}" ]] \
  && ! grep -Fqx "${last_delta}" "${INDEX_FILE}"; then
  log "Checkpoint ${last_delta} is no longer present in the 14-day delta window."
  log "Run /opt/off-sync/full-rebuild.sh before applying more deltas."
  exit 2
fi

process_delta=false
if [[ "${FORCE_ALL}" == "true" || -z "${last_delta}" ]]; then
  process_delta=true
fi

processed=0
while IFS= read -r delta_file; do
  if [[ "${process_delta}" != "true" ]]; then
    if [[ "${delta_file}" == "${last_delta}" ]]; then
      process_delta=true
    fi
    continue
  fi

  if [[ "${FORCE_ALL}" != "true" && "${delta_file}" == "${last_delta}" ]]; then
    continue
  fi

  delta_end="${delta_file%.json.gz}"
  delta_end="${delta_end##*_}"
  if (( delta_end <= MIN_DELTA_END )); then
    checkpoint_tmp="${STATE_FILE}.tmp"
    printf '%s\n' "${delta_file}" > "${checkpoint_tmp}"
    mv "${checkpoint_tmp}" "${STATE_FILE}"
    continue
  fi

  delta_path="${DELTA_DIR}/${delta_file}"
  delta_tmp="${delta_path}.part"
  normalized_path="${DELTA_DIR}/${delta_file%.json.gz}.jsonl"
  normalized_tmp="${normalized_path}.tmp"

  log "Downloading ${delta_file}."
  if ! gzip --test "${delta_tmp}" 2>/dev/null; then
    curl --fail --location --show-error \
      --retry 5 --retry-all-errors --continue-at - \
      --output "${delta_tmp}" \
      "${DELTA_BASE_URL}/${delta_file}"
  fi
  gzip --test "${delta_tmp}"
  mv "${delta_tmp}" "${delta_path}"

  log "Upserting ${delta_file} into MongoDB."
  gzip --decompress --stdout "${delta_path}" \
    | mongoimport \
        --uri="${MONGO_URI}" \
        --db=off \
        --collection=products \
        --type=json \
        --mode=upsert \
        --upsertFields=_id \
        --stopOnError

  log "Converting ${delta_file} to Search-a-licious JSONL."
  gzip --decompress --stdout "${delta_path}" \
    | jq --compact-output '
        select(.code != null and .code != "")
        | .code = (.code | tostring)
        | .obsolete = (.obsolete // false)
        | del(._id)
      ' \
    > "${normalized_tmp}"
  mv "${normalized_tmp}" "${normalized_path}"

  if [[ "${SKIP_ES}" != "true" && -s "${normalized_path}" ]]; then
    log "Partially importing ${delta_file} into Elasticsearch."
    python3 -m app import "${normalized_path}" \
      --partial \
      --skip-updates \
      --num-processes "${IMPORT_PROCESSES}"
  fi

  checkpoint_tmp="${STATE_FILE}.tmp"
  printf '%s\n' "${delta_file}" > "${checkpoint_tmp}"
  mv "${checkpoint_tmp}" "${STATE_FILE}"
  rm -f "${delta_path}" "${normalized_path}"
  processed=$((processed + 1))
done < "${INDEX_FILE}"

log "Delta synchronization completed; processed ${processed} file(s)."

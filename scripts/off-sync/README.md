# Open Food Facts synchronization

The `sync` Compose service maintains a local MongoDB copy of Open Food Facts and
imports it into Search-a-licious.

## Commands

Run a full MongoDB restore and build a new Elasticsearch index:

```sh
/opt/off-sync/full-rebuild.sh
```

Apply all unprocessed daily deltas to MongoDB and the current Elasticsearch
index:

```sh
/opt/off-sync/sync-deltas.sh
```

The scripts use `/opt/search/data/off-sync` for downloads, checkpoints and their
shared lock. Delta files are applied oldest first. If the checkpoint has fallen
out of the 14-day delta window, the delta command stops and requires a full
rebuild. Full rebuilds apply all available deltas after restoring the snapshot,
but skip delta files ending before the dump's HTTP `Last-Modified` time. They
then create a new Elasticsearch index and switch the alias only after indexing.

Products marked `empty` are intentionally retained if they have a barcode. The
upstream CSV and JSONL exports can omit such records, while barcode lookup still
needs them.

## Coolify scheduled tasks

Create both tasks on the `sync` Compose component with a timeout of 36000
seconds:

| Name | Cron | Command |
| --- | --- | --- |
| Daily OFF deltas | `30 5 * * *` | `/opt/off-sync/sync-deltas.sh` |
| Weekly OFF rebuild | `30 1 * * 0` | `/opt/off-sync/full-rebuild.sh` |

The schedules use the deployment server's timezone. Run the full rebuild once
manually before enabling the daily delta task.

If a full rebuild is interrupted after MongoDB has already been restored, resume
it from the MongoDB-to-JSONL export without downloading and restoring the dump
again:

```bash
OFF_SYNC_RESUME_FROM_EXPORT=true /opt/off-sync/full-rebuild.sh
```

If a temporary JSONL export exists, the resume command validates it and rebuilds
its product count in one pass. A valid export is reused before starting the
Elasticsearch import; an incomplete export is recreated from MongoDB.

Use this as a one-off command only. Leaving the variable enabled for the weekly
task would skip the dump download, MongoDB restore, and initial delta sync.

By default inactive Elasticsearch indexes are retained for rollback. Set
`OFF_SYNC_CLEANUP_INDEXES=true` to delete them automatically after a successful
full rebuild.

#!/bin/bash
# Generate and commit thumbnails for every item Synology Photos marked as failed
# (thumbnail.status = 3), using the NAS's own CPU. No Docker: uses the SynoCommunity
# imagemagick and ffmpeg packages directly.
#
# Usage (on the NAS, as root):
#   sudo PHOTOS_USER=<dsm user> ./run-batch.sh              # until the backlog is empty
#   sudo PHOTOS_USER=<dsm user> ./run-batch.sh --limit 50   # first 50 only (trial)
#   sudo PHOTOS_USER=<dsm user> ./run-batch.sh --dry-run    # generate into work/stage, commit nothing
# Env: JOBS=3 parallel decoders, BATCH=200 items per batch, WORK=<dir>, PHOTOS_DIR=<dir>
#
# Safe to run while the official client is also repairing: commit-one.sh re-checks the
# status and skips anything already fixed.
set -uo pipefail
. "$(dirname "$0")/config.sh"
[ -n "$PHOTOS_USER" ] || { echo "set PHOTOS_USER"; exit 2; }
UID_DB=$(photos_uid); [ -n "$UID_DB" ] || { echo "user $PHOTOS_USER not in Photos DB"; exit 2; }
for b in "$CONVERT" "$FFMPEG"; do [ -x "$b" ] || { echo "missing $b (install the SynoCommunity package)"; exit 2; }; done

JOBS="${JOBS:-3}"; BATCH="${BATCH:-200}"; LIMIT=0; DRY=0
while [ $# -gt 0 ]; do case "$1" in
  --limit) LIMIT="$2"; shift 2;; --dry-run) DRY=1; shift;; *) echo "unknown option $1"; exit 2;; esac; done

HERE=$(cd "$(dirname "$0")" && pwd)
export STAGE=$WORK/stage PHOTOS_DIR WORK
LOG=$WORK/log/run-$(date +%F-%H%M%S).log; SKIP=$WORK/skip.ids
mkdir -p "$STAGE" "$WORK/log" "$WORK/backup"; touch "$SKIP"
say() { echo "$(date +%T) $*" | tee -a "$LOG"; }

# Schema guard: refuse to write if the tables this script relies on have changed.
EXPECT="thumbnail:id_unit,status,type thumbnail_version:id_unit,id_user,sm_size_hash,version unit:cache_key,filename,id_folder,id_user,type"
for spec in $EXPECT; do
  t=${spec%%:*}; want=${spec#*:}
  inlist=$(echo "$want" | sed "s/,/','/g; s/^/'/; s/\$/'/")     # a,b -> 'a','b' (portable across bash versions)
  have=$(psql -At -c "select string_agg(column_name,',' order by column_name) from information_schema.columns where table_schema='public' and table_name='$t' and column_name in ($inlist)")
  [ "$have" = "$want" ] || { say "schema check failed for table $t: have [$have], want [$want]. Photos may have changed; stopping."; exit 4; }
done
psql -At -c "select 1 from information_schema.triggers where trigger_name='update_unit_version_trigger' limit 1" | grep -q 1 \
  || { say "update_unit_version_trigger missing; stopping."; exit 4; }

# Table dump once per day (per-item backups are made by commit-one.sh).
DUMP=$WORK/backup/tables-$(date +%F).sql.gz
[ -f "$DUMP" ] || { sudo -u postgres pg_dump -d synofoto -t thumbnail -t thumbnail_version | gzip > "$DUMP"; say "backup: $DUMP"; }

done_n=0; ok_n=0; skip_n=0; err_n=0
while :; do
  n=$BATCH; [ "$LIMIT" -gt 0 ] && { left=$((LIMIT-done_n)); [ $left -le 0 ] && break; [ $left -lt $n ] && n=$left; }
  skipcsv=$(paste -sd, "$SKIP"); [ -z "$skipcsv" ] && skipcsv=0
  rm -f "$STAGE"/*.jpg "$STAGE/list.tsv"; : > "$STAGE/errors.log"
  psql -At -F $'\t' -c "select u.id, u.type, f.name||'/'||u.filename
      from unit u join folder f on f.id=u.id_folder
      join thumbnail t on t.id_unit=u.id and t.type=0 and t.status=3
     where u.id_user=$UID_DB and u.id not in ($skipcsv) order by u.id desc limit $n" > "$STAGE/list.tsv"
  cnt=$(wc -l < "$STAGE/list.tsv"); [ "$cnt" -eq 0 ] && { say "backlog empty"; break; }
  say "batch of $cnt, generating (JOBS=$JOBS)..."

  tr '\t\n' '\0\0' < "$STAGE/list.tsv" | nice -n 19 xargs -0 -n 3 -P "$JOBS" "$HERE/gen-one.sh" >> "$LOG" 2>&1

  while IFS=$'\t' read -r id type rel; do
    done_n=$((done_n+1))
    if [ ! -s "$STAGE/$id.SM.jpg" ]; then err_n=$((err_n+1)); echo "$id" >> "$SKIP"; continue; fi
    [ "$DRY" = 1 ] && continue
    out=$("$HERE/commit-one.sh" "$id" 2>&1); rc=$?
    if [ $rc -ne 0 ]; then say "commit failed for unit $id rc=$rc: $out"; say "stopping - do not push through commit errors"; exit 1; fi
    case "$out" in *skipping*) skip_n=$((skip_n+1));; *) ok_n=$((ok_n+1));; esac
    rm -f "$STAGE/$id".*.jpg
  done < "$STAGE/list.tsv"
  cat "$STAGE/errors.log" >> "$WORK/log/errors-all.log"
  say "total: processed $done_n / committed $ok_n / already fixed elsewhere $skip_n / generation failed $err_n"
  [ "$DRY" = 1 ] && { say "dry run: thumbnails left in $STAGE, nothing committed"; break; }
done
say "finished. remaining failures: $(psql -At -c "select count(*) from thumbnail where type=0 and status=3")"

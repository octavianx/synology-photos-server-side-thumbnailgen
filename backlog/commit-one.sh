#!/bin/bash
# Hand the three staged thumbnails of one item to Synology Photos.
#
# Usage (on the NAS, as root):  sudo PHOTOS_USER=<dsm user> ./commit-one.sh <unit_id>
# Roll back:                    sudo PHOTOS_USER=<dsm user> ./commit-one.sh <unit_id> --rollback
#
# Does exactly what Photos does after the official client uploads thumbnails
# (derived by diffing a client-repaired item against a failed one, Photos 1.8.0):
#   1. @eaDir/<file>/SYNOPHOTO_THUMB_{SM,M,XL}.jpg on disk
#   2. remove the matching .fail markers (moved to a backup dir, not deleted)
#   3. in one transaction: thumbnail.status 3->1 (types 0/1/3),
#                          thumbnail_version row with sm_size_hash = MD5(SM.jpg) uppercase,
#                          unit.cache_key = now (a trigger bumps unit.version from that)
set -euo pipefail
. "$(dirname "$0")/config.sh"

ID="${1:?unit id}"; MODE="${2:-commit}"
[ -n "$PHOTOS_USER" ] || { echo "set PHOTOS_USER"; exit 2; }
UID_DB=$(photos_uid); [ -n "$UID_DB" ] || { echo "user $PHOTOS_USER not in Photos DB"; exit 2; }
ST=$WORK/stage; BK=$WORK/backup/$ID

[[ "$ID" =~ ^[0-9]+$ ]] || { echo "unit id must be numeric"; exit 2; }
REL=$(psql -At -c "select f.name||'/'||u.filename from unit u join folder f on f.id=u.id_folder where u.id=$ID and u.id_user=$UID_DB")
[ -n "$REL" ] || { echo "unit $ID not found for user $PHOTOS_USER"; exit 2; }
SRC="$PHOTOS_DIR$REL"; EA="$(dirname "$SRC")/@eaDir/$(basename "$SRC")"
[ -f "$SRC" ] || { echo "source missing: $SRC"; exit 2; }
echo "unit $ID -> $REL"

if [ "$MODE" = "--rollback" ]; then
  [ -f "$BK/state.txt" ] || { echo "no backup at $BK"; exit 2; }
  OLD_KEY=$(cut -d'|' -f1 "$BK/state.txt")
  for z in SM M XL; do
    mv "$EA/SYNOPHOTO_THUMB_$z.jpg" "$BK/" 2>/dev/null || true
    [ -e "$BK/SYNOPHOTO_THUMB_$z.fail" ] && mv "$BK/SYNOPHOTO_THUMB_$z.fail" "$EA/"
  done
  psql -q <<SQL
begin;
update thumbnail set status=3 where id_unit=$ID and type in (0,1,3);
delete from thumbnail_version where id_unit=$ID;
update unit set cache_key='$OLD_KEY' where id=$ID;
commit;
SQL
  echo "rolled back"; exit 0
fi

# ---- pre-flight ----
require_tested_photos_version || exit 5
for z in SM M XL; do
  f=$ST/$ID.$z.jpg
  [ "$(od -An -tx1 -N2 "$f" | tr -d ' ')" = "ffd8" ] && [ "$(stat -c %s "$f")" -gt 1000 ] \
    || { echo "staged file is not a JPEG: $f"; exit 3; }
done
ST_NOW=$(psql -At -c "select status from thumbnail where id_unit=$ID and type=0")
[ "$ST_NOW" = "3" ] || { echo "status=$ST_NOW is not 3 - already repaired elsewhere, skipping"; exit 0; }
[ -e "$EA/SYNOPHOTO_THUMB_SM.jpg" ] && { echo "SM.jpg already exists, skipping"; exit 0; }

# ---- keep what we change ----
mkdir -p "$BK"
psql -At -c "select cache_key, version from unit where id=$ID" > "$BK/state.txt"

# ---- files (write .tmp then mv, so Photos never sees a half-written file) ----
for z in SM M XL; do
  t="$EA/SYNOPHOTO_THUMB_$z.jpg"
  cp "$ST/$ID.$z.jpg" "$t.tmp"; chown root:root "$t.tmp"; chmod 644 "$t.tmp"; mv "$t.tmp" "$t"
  [ -e "$EA/SYNOPHOTO_THUMB_$z.fail" ] && mv "$EA/SYNOPHOTO_THUMB_$z.fail" "$BK/"
done

# ---- database ----
MD5=$(md5sum "$EA/SYNOPHOTO_THUMB_SM.jpg" | cut -c1-32 | tr a-z A-Z)
NOW=$(date +%s)
psql -q <<SQL
begin;
update thumbnail set status=1 where id_unit=$ID and type in (0,1,3) and status=3;
insert into thumbnail_version(id_user,id_unit,version,sm_size_hash)
  select $UID_DB,$ID,1,'$MD5' where not exists (select 1 from thumbnail_version where id_unit=$ID);
update unit set cache_key='$NOW' where id=$ID;
commit;
SQL

echo "done:"
psql -At -c "select 'cache_key='||u.cache_key||' version='||u.version||' status=['||(select string_agg(t.type||':'||t.status,' ' order by t.type) from thumbnail t where t.id_unit=u.id)||']' from unit u where u.id=$ID"

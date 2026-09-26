# Shared settings for the backlog scripts. Sourced by run-batch.sh, commit-one.sh, gen-one.sh.
# Override any of these with environment variables.

# DSM user whose personal space (Photos folder) to process.
PHOTOS_USER=${PHOTOS_USER:-${SUDO_USER:-}}
# Absolute path of that user's Photos folder (resolve the symlink so paths match the DB).
PHOTOS_DIR=${PHOTOS_DIR:-$(readlink -f "/var/services/homes/$PHOTOS_USER")/Photos}
# Working directory: staging, backups, logs. Must be on a volume (/tmp is noexec on DSM).
WORK=${WORK:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/work}

# Decoders (SynoCommunity packages).
CONVERT=/var/packages/imagemagick/target/bin/convert
IDENTIFY=/var/packages/imagemagick/target/bin/identify
FFMPEG=/var/packages/ffmpeg/target/bin/ffmpeg
FFPROBE=/var/packages/ffmpeg/target/bin/ffprobe

# Photos database access (runs as root via sudo).
psql() { sudo -u postgres psql -d synofoto -v ON_ERROR_STOP=1 "$@"; }

# Numeric id_user in the Photos DB for PHOTOS_USER.
photos_uid() { psql -At -c "select id from user_info where name='$PHOTOS_USER'"; }

# Synology Photos version these scripts were verified against. The backlog scripts write to
# Photos' private database; refuse to run on any other version unless ALLOW_UNTESTED=1.
TESTED_PHOTOS_VERSION=${TESTED_PHOTOS_VERSION:-1.8.0-10070}
require_tested_photos_version() {
  local v; v=$(/usr/syno/bin/synopkg version SynologyPhotos 2>/dev/null)
  [ "$v" = "$TESTED_PHOTOS_VERSION" ] && return 0
  echo "Synology Photos $v is installed; these scripts were verified on $TESTED_PHOTOS_VERSION only." >&2
  [ "${ALLOW_UNTESTED:-0}" = "1" ] && { echo "ALLOW_UNTESTED=1 set, continuing at your own risk." >&2; return 0; }
  echo "Refusing to write to the Photos database. Run with --dry-run to test decoding, or set ALLOW_UNTESTED=1" >&2
  echo "and start with --limit 1, then check the item in Photos and keep --rollback at hand." >&2
  return 5
}

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

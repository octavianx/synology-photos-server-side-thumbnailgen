#!/bin/bash
# Install the "AME shim" under /var/packages/CodecPack so DSM's thumbnailer hands
# HEIC/HEVC decoding to SynoCommunity ImageMagick and ffmpeg.
#
# Usage (on the NAS, as root):   sudo ./install-shim.sh          # install (idempotent)
#                                sudo ./install-shim.sh --off    # disable: rename the dir, delete nothing
#
# Creates files only inside a directory that does not exist on a DSM 7.2.2+ system
# without AME. Modifies no Synology file. Deliberately leaves /usr/syno/bin/synocodectool
# alone - that is a real DSM binary.
set -euo pipefail

P=/var/packages/CodecPack
SHIM_DIR=$(cd "$(dirname "$0")" && pwd)        # where this script and stub.sh live
LOGDIR=${SHIM_LOG:-$SHIM_DIR/log}             # override with SHIM_LOG=/path
MARK="photos-heic-shim"

if [ "${1:-}" = "--off" ]; then
  [ -d "$P" ] || { echo "no $P, nothing to do"; exit 0; }
  grep -q "$MARK" "$P/INFO" 2>/dev/null || { echo "refusing: $P is not the shim (no '$MARK' in INFO)"; exit 2; }
  mv "$P" "$P.shim-off-$(date +%F-%H%M%S)"; echo "disabled (directory renamed, nothing deleted)"; exit 0
fi

if [ -e "$P" ] && ! grep -q "$MARK" "$P/INFO" 2>/dev/null; then
  echo "refusing: $P exists and is not the shim (real Advanced Media Extensions installed?)"; ls -la "$P"; exit 2
fi
[ -x /var/packages/imagemagick/target/bin/magick ] || { echo "SynoCommunity imagemagick package not found"; exit 2; }
[ -x /var/packages/ffmpeg/target/bin/ffmpeg ]     || { echo "SynoCommunity ffmpeg package not found"; exit 2; }

mkdir -p "$P/target/usr/bin" "$P/target/pack/usr/bin" "$P/target/pack/bin" "$LOGDIR"
chmod 1777 "$LOGDIR"
echo "LOGDIR=$LOGDIR" > "$P/target/shim.conf"

# Version 30.x is higher than any real AME, so Package Center never "upgrades" it to AME 4.0.
cat > "$P/INFO" <<EOF
package="CodecPack"
version="30.1.0-3005"
displayname="Advanced Media Extensions (shim)"
description="NOT Synology AME. A shim that routes HEIC/HEVC decoding to SynoCommunity ImageMagick and ffmpeg."
arch="x86_64"
maintainer="$MARK"
os_min_ver="7.0-40000"
startable="no"
ctl_stop="no"
EOF

# Gate files DSM checks: INFO above, plus HAS_HEVC. (`enabled` is not needed; DSM deletes it at boot.)
# Declare only HEVC - not H264/AAC/VC1 - so DSM does not try to route video transcoding here.
: > "$P/target/pack/HAS_HEVC"

# Paths DSM 7.2.2 actually calls (from /var/log/messages): target/pack/...
install -m 755 "$SHIM_DIR/stub.sh" "$P/target/pack/usr/bin/convert"
install -m 755 "$SHIM_DIR/stub.sh" "$P/target/pack/bin/ffmpeg41"
# Path referenced by libsynothumb.so on another code path:
install -m 755 "$SHIM_DIR/stub.sh" "$P/target/usr/bin/convert"
# Licence-check stubs (never observed being called):
install -m 755 "$SHIM_DIR/stub.sh" "$P/target/usr/bin/synoame-bin-check-license"
install -m 755 "$SHIM_DIR/stub.sh" "$P/target/usr/bin/synoame-bin-request-codec"

echo "shim installed:"; find "$P" -type f -printf '  %M %u %s  %p\n'
echo "call log: $LOGDIR/calls.log"

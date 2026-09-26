#!/bin/bash
# Generate SM/M/XL thumbnails for one Photos item into the staging directory.
# Args: <unit_id> <type: 0=photo 1=video> <path relative to PHOTOS_DIR, leading slash>
# Never writes into the Photos folder. Failures go to $STAGE/errors.log, no partial output.
set -u
. "$(dirname "$0")/config.sh"
STAGE=${STAGE:-$WORK/stage}

id=$1; type=$2; rel=$3
src="$PHOTOS_DIR$rel"; o="$STAGE/$id"
fail() { echo "$id|$rel|$1" >> "$STAGE/errors.log"; rm -f "$o".*.jpg "$o.frame.jpg"; exit 0; }

[ -f "$src" ] || fail "source file missing"
in="$src[0]"

if [ "$type" = "1" ]; then
  # Video: grab one frame. Tone-map HLG/PQ to SDR, otherwise the poster looks washed out.
  trc=$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=color_transfer -of csv=p=0 "$src" 2>/dev/null)
  vf=""
  case "$trc" in arib-std-b67|smpte2084)
    vf="zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p" ;;
  esac
  ok=""
  for ss in 1 0; do
    for f in "$vf" ""; do
      rm -f "$o.frame.jpg"
      if [ -n "$f" ]; then
        "$FFMPEG" -nostdin -v error -y -ss $ss -i "$src" -frames:v 1 -vf "$f" -q:v 2 "$o.frame.jpg" 2>/dev/null
      else
        "$FFMPEG" -nostdin -v error -y -ss $ss -i "$src" -frames:v 1 -q:v 2 "$o.frame.jpg" 2>/dev/null
      fi
      [ -s "$o.frame.jpg" ] && { ok=1; break 2; }
      [ -z "$vf" ] && break
    done
  done
  [ -n "$ok" ] || fail "ffmpeg could not extract a frame"
  in="$o.frame.jpg"
fi

# Same size rule as Synology: short side 1280 / 320 / 240, shrink only. ICC profile kept.
"$CONVERT" "$in" -auto-orient -write mpr:src +delete \
  \( mpr:src -thumbnail "1280x1280^>" -quality 85 -write "$o.XL.jpg" +delete \) \
  \( mpr:src -thumbnail "320x320^>"   -quality 85 -write "$o.M.jpg"  +delete \) \
  mpr:src -thumbnail "240x240^>" -quality 85 "$o.SM.jpg" 2>/dev/null
rm -f "$o.frame.jpg"
[ -s "$o.SM.jpg" ] && [ -s "$o.M.jpg" ] && [ -s "$o.XL.jpg" ] || fail "ImageMagick could not decode/scale"

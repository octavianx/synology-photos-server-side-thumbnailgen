#!/bin/sh
# Shim installed under /var/packages/CodecPack/ in place of Synology's converters.
# Behaviour depends on the name it is invoked as:
#   convert                   -> forward to SynoCommunity ImageMagick (reads iOS 18+ HEIC)
#   ffmpeg41                  -> only "extract one frame" calls; HDR (HLG/PQ) is tone-mapped.
#                                Anything else is logged and refused.
#   synoame-bin-*             -> log and exit 0 (DSM never calls these in practice)
# Not a Synology program. Uses no Synology HEVC decoder.

LOGDIR=/var/packages/CodecPack/target/log
[ -r /var/packages/CodecPack/target/shim.conf ] && . /var/packages/CodecPack/target/shim.conf
LOG=$LOGDIR/calls.log
CONVERT=${SHIM_CONVERT:-/var/packages/imagemagick/target/bin/convert}   # SHIM_CONVERT: tests only
SYS_CONVERT=/usr/bin/convert
FFMPEG=/var/packages/ffmpeg/target/bin/ffmpeg
FFPROBE=/var/packages/ffmpeg/target/bin/ffprobe
me=$(basename "$0")

# rotate at 5 MB
[ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 5242880 ] && mv -f "$LOG" "$LOG.1" 2>/dev/null
say() { echo "$(date '+%F %T') $me $*" >> "$LOG" 2>/dev/null; }
last() { for _a in "$@"; do :; done; echo "$_a"; }

case "$me" in
  convert)
    # 1) Drop `-define jpeg:size=WxH`: under ImageMagick 7 this decode hint mis-sizes the
    #    output (1080x1920 frame -> XL upscaled to 1215x2160, M shrunk to 270x480).
    n=$#; i=0
    while [ $i -lt $n ]; do
      a=$1; shift; i=$((i+1))
      if [ "$a" = "-define" ] && [ $i -lt $n ]; then
        case "$1" in jpeg:size=*) shift; i=$((i+1)); continue ;; esac
      fi
      set -- "$@" "$a"
    done
    # 2) Use the `convert` compatibility entry point: DSM passes operators before the input
    #    file (IM6 style) for video frames; strict `magick` rejects that with NoImagesFound.
    #    The entry point prints a deprecation warning on every run; filter it.
    err=$(mktemp "$LOGDIR/.err.XXXXXX" 2>/dev/null) || err=/dev/null
    rc=127
    [ -x "$CONVERT" ] && { "$CONVERT" "$@" 2> "$err"; rc=$?; }
    [ "$err" != /dev/null ] && { grep -v 'deprecated in IMv7' "$err" | grep -v '^$' >> "$LOG.stderr"; rm -f "$err"; }
    # 3) Safety net: once the shim exists DSM routes ALL photos (JPEG too) through it.
    #    If our converter is missing or fails, fall back to DSM's own ImageMagick 6:
    #    JPEG keeps working, only HEIC fails.
    if [ $rc -ne 0 ] && [ -x "$SYS_CONVERT" ]; then
      say "fallback->system convert (rc=$rc) out=$(last "$@")"
      "$SYS_CONVERT" "$@" 2>> "$LOG.stderr"; rc=$?
    fi
    [ $rc -eq 0 ] || say "FAIL rc=$rc out=$(last "$@")"
    exit $rc
    ;;

  ffmpeg41)
    # Accept only DSM's poster-frame call: ... -i IN ... -vframes 1 ... -f mjpeg OUT
    in=; prev=; one=; mj=
    for a in "$@"; do
      [ "$prev" = "-i" ] && in=$a
      [ "$prev" = "-vframes" ] && [ "$a" = "1" ] && one=1
      [ "$prev" = "-f" ] && [ "$a" = "mjpeg" ] && mj=1
      prev=$a
    done
    if [ -z "$one" ] || [ -z "$mj" ] || [ -z "$in" ]; then
      say "REFUSED (not a frame-extract call) args: $*"
      exit 1
    fi
    trc=$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=color_transfer -of csv=p=0 "$in" 2>/dev/null)
    case "$trc" in
      arib-std-b67|smpte2084)
        # insert -vf before the output file (last argument)
        n=$#; i=1
        while [ $i -lt $n ]; do a=$1; shift; set -- "$@" "$a"; i=$((i+1)); done
        out=$1; shift
        set -- "$@" -vf "zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p" "$out"
        ;;
    esac
    "$FFMPEG" -nostdin -hide_banner -loglevel error "$@" 2>> "$LOG.stderr"; rc=$?
    [ $rc -eq 0 ] && say "frame ok ${trc:+($trc) }$in" || say "FAIL rc=$rc $in"
    exit $rc
    ;;

  *)
    say "called args: $*"
    exit 0
    ;;
esac

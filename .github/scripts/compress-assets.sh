#!/usr/bin/env bash
set -euo pipefail

MAP_FILE="${MAP_FILE:-compressed-assets-map.txt}"
FORCE="${FORCE:-false}"
MAP_SEPARATOR=" ===> "
REPORT="${REPORT:-/dev/stdout}"
DRY_RUN="${DRY_RUN:-false}"
SVGO_CONFIG="${SVGO_CONFIG:-}"

OXI_ARGS="-o 0"
ZOPFLI_ARGS="-m --iterations=5 --filters=0me"
X265_PRESET="slower"
VIDEO_CRF="22"
VIDEO_MIN_GAIN="10"

size_of() { stat -c%s "$1"; }

keep_if_smaller() {
  local cand="$1" target="$2"
  if [ -s "$cand" ] && [ "$(size_of "$cand")" -lt "$(size_of "$target")" ]; then
    mv -f "$cand" "$target"
  else
    rm -f "$cand"
  fi
}

opt_png() {
  local f="$1"

  oxipng $OXI_ARGS --strip all --quiet "$f" || true

  zopflipng $ZOPFLI_ARGS -y "$f" "$f.zopfli.png" >/dev/null 2>&1 || true
  keep_if_smaller "$f.zopfli.png" "$f"
}

opt_jpeg() {
  local f="$1"

  jpegtran -copy none -optimize -outfile "$f.base.jpg" "$f" >/dev/null 2>&1 || true
  keep_if_smaller "$f.base.jpg" "$f"

  jpegtran -copy none -optimize -progressive -outfile "$f.prog.jpg" "$f" >/dev/null 2>&1 || true
  keep_if_smaller "$f.prog.jpg" "$f"

  jpegoptim --strip-all --quiet "$f" >/dev/null 2>&1 || true
}

opt_gif() {
  local f="$1"
  gifsicle -O3 --careful -o "$f.gifsicle.gif" "$f" >/dev/null 2>&1 || true
  keep_if_smaller "$f.gifsicle.gif" "$f"
}

opt_svg() {
  local f="$1"
  svgo --quiet --config "$SVGO_CONFIG" -i "$f" -o "$f.svgo.svg" >/dev/null 2>&1 || true
  keep_if_smaller "$f.svgo.svg" "$f"

  if command -v svgcleaner >/dev/null; then
    svgcleaner "$f" "$f.svgcleaner.svg" >/dev/null 2>&1 || true
    keep_if_smaller "$f.svgcleaner.svg" "$f"
  fi
}

opt_video() {
  local f="$1" codec pix_fmt audio_args=() out="$1.hevc.mp4"

  codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$f" || true)
  case "$codec" in
    hevc) echo "skip (already HEVC): $ORIGINAL_PATH"; return 0 ;;
    '')   echo "skip (no video stream): $ORIGINAL_PATH"; return 0 ;;
  esac

  pix_fmt=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of csv=p=0 "$f" || true)
  case "$pix_fmt" in
    *a*) echo "skip (alpha channel): $ORIGINAL_PATH"; return 0 ;;
  esac

  if ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$f" | grep -q .; then
    audio_args=(-map '0:a?' -c:a copy)
  else
    audio_args=(-an)
  fi

  ffmpeg -nostdin -v error -y -i "$f" \
    -map 0:v:0 "${audio_args[@]}" \
    -c:v libx265 -crf "$VIDEO_CRF" -preset "$X265_PRESET" -tag:v hvc1 \
    -map_metadata -1 -movflags +faststart \
    "$out" >/dev/null 2>&1 || { rm -f "$out"; return 0; }

  if [ -s "$out" ] && [ "$(( $(size_of "$out") * 100 ))" -lt "$(( $(size_of "$f") * (100 - VIDEO_MIN_GAIN) ))" ]; then
    mv -f "$out" "$f"
  else
    echo "skip (gain below ${VIDEO_MIN_GAIN}%): $ORIGINAL_PATH"
    rm -f "$out"
  fi
}

optimize_one() {
  local f="$1"
  local before after tmpdir work
  local ORIGINAL_PATH="$1"

  before=$(size_of "$f")
  [ "$before" -gt 0 ] || return 0

  if [ "$FORCE" != "true" ] && [ -f "$MAP_FILE" ] &&
    awk -F"$MAP_SEPARATOR" -v p="$f" -v h="$(sha256sum "$f" | cut -d' ' -f1)" \
      '$1 == p { found = ($2 == h); exit } END { exit !found }' "$MAP_FILE"; then
    return 0
  fi

  echo "start: $f ($before B)"

  tmpdir=$(mktemp -d)
  work="$tmpdir/asset"
  cp "$f" "$work"

  case "${f,,}" in
    *.png)          opt_png "$work" ;;
    *.jpg|*.jpeg)   opt_jpeg "$work" ;;
    *.gif)          opt_gif "$work" ;;
    *.svg)          opt_svg "$work" ;;
    *.mp4|*.m4v)    opt_video "$work" ;;
  esac

  after=$(size_of "$work")
  if [ "$after" -le 0 ] || [ "$after" -ge "$before" ]; then
    after=$before
  elif [ "$DRY_RUN" != "true" ]; then
    cat "$work" > "$f"
  fi
  rm -rf "$tmpdir"

  echo "done:  $f ($before B -> $after B, $(awk -v b="$before" -v a="$after" \
    'BEGIN { printf "-%.1f%%", (b - a) * 100 / b }'))"

  printf '%s\t%s\t%s\n' "$before" "$after" "$f" >> "$REPORT"
  if [ "$DRY_RUN" != "true" ]; then
    printf '%s%s%s\n' "$f" "$MAP_SEPARATOR" "$(sha256sum "$f" | cut -d' ' -f1)" >> "$NEW_ENTRIES"
  fi
}

NEW_ENTRIES=$(mktemp)
trap 'rm -f "$NEW_ENTRIES"' EXIT

export MAP_FILE MAP_SEPARATOR FORCE NEW_ENTRIES REPORT DRY_RUN SVGO_CONFIG
export OXI_ARGS ZOPFLI_ARGS
export VIDEO_CRF VIDEO_MIN_GAIN X265_PRESET
export -f size_of
export -f keep_if_smaller opt_png opt_jpeg opt_gif opt_svg opt_video optimize_one

readarray -d '' CANDIDATES < <(git ls-files -z)

VIDEOS=()
IMAGES=()
for f in "${CANDIDATES[@]}"; do
  case "${f,,}" in
    *.mp4|*.m4v) [ -f "$f" ] && VIDEOS+=("$f") ;;
    *.png|*.jpg|*.jpeg|*.gif|*.svg) [ -f "$f" ] && IMAGES+=("$f") ;;
  esac
done

FILES=("${VIDEOS[@]}" "${IMAGES[@]}")

echo "Found ${#FILES[@]} file(s) (${#VIDEOS[@]} video), jobs=$(nproc)"
[ "${#FILES[@]}" -gt 0 ] || exit 0

printf '%s\0' "${FILES[@]}" | xargs -0 -P "$(nproc)" -I{} bash -c 'optimize_one "$@"' _ {}

if [ "$DRY_RUN" != "true" ]; then
  MAP_DRAFT=$(mktemp)
  trap 'rm -f "$NEW_ENTRIES" "$MAP_DRAFT"' EXIT

  KEPT=$(mktemp)
  if [ -f "$MAP_FILE" ]; then
    awk -F"$MAP_SEPARATOR" -v new="$NEW_ENTRIES" -v sep="$MAP_SEPARATOR" '
      BEGIN { while ((getline line < new) > 0) { split(line, f, sep); seen[f[1]] } }
      /^\/\// || NF < 2 { next }
      !($1 in seen) { print }
    ' "$MAP_FILE" |
      while IFS= read -r entry; do
        map_path="${entry%%"$MAP_SEPARATOR"*}"
        if [ -n "$map_path" ] && [ -f "$map_path" ]; then
          printf '%s\n' "$entry"
        fi
      done > "$KEPT"
  fi

  {
    echo "//"
    echo "// Assets already compressed by the Compress assets workflow."
    echo "// An asset is squeezed again once its hash changes."
    echo "//"
    echo "// <path> ===> <sha256>"
    echo "//"
    echo
    cat "$NEW_ENTRIES" "$KEPT" | LC_ALL=C sort
  } > "$MAP_DRAFT"
  rm -f "$KEPT"

  cat "$MAP_DRAFT" > "$MAP_FILE"
  echo "Map: $(grep -cv '^//\|^$' "$MAP_FILE" || true) entry(ies) in $MAP_FILE"
fi

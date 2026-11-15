#!/usr/bin/env bash
# Fetches the public-domain sources of OrbitSim's Earth tiles (M1.6 track
# E1, docs/m16/planet-tile-cache.md) for `PlanetTiles earth all`. Owner-run:
# about 7 GB by default. Nothing here is committed.
#
#   tools/fetch_planet_data.sh --dry-run        # what would come, and how big (HEAD requests only)
#   tools/fetch_planet_data.sh                  # everything: BMNG July and December, Natural Earth, ETOPO 2022, Landsat
#   tools/fetch_planet_data.sh --only natural-earth,etopo
#
# Options:
#   --dest DIR          where the files go (default ~/Library/Application Support/OrbitSim/Sources/earth)
#   --months LIST       BMNG 2004 months, two digits, comma-separated (default 07,12; add 10 for Apollo 7)
#   --bmng-format FMT   tif: NASA's lossless GeoTIFFs, about 2.5 GB a month (default);
#                       jpg: NASA's JPEGs, about 0.36 GB a month (re-encoded once more as tiles)
#   --only LIST         some of: bmng, natural-earth, etopo, landsat
#   --landsat-scene ID  the Cape scene (default LC09_L1TP_016040_20221209_20230318_02_T1)
#   --landsat-aws       fetch the scene from s3://usgs-landsat with your AWS credentials (requester pays,
#                       about $0.01); without it the script lists the five files to download yourself
#                       from LandsatLook while signed in to USGS ERS, then checks them on the next run
#   --dry-run           print each file's URL and size, and the total; download nothing
#
# It first lists every file, asks the servers their sizes, and prints how
# much it will download and how much space the disk has; it stops if the
# download would not fit, and warns if building the tiles afterwards (up to
# 15 GB of scratch, about 3 GB of tiles) would not. Downloads resume (curl
# -C -) and land under DIR/<dataset>/. Each file is checked against its size
# and recorded in DIR/SOURCES.txt with its URL, date, licence, credit and
# sha256, and a note of what PlanetTiles changes in it; a file already
# recorded with a matching sha256 is not fetched again. PlanetTiles copies
# these lines into each tile file's metadata.
set -euo pipefail
# Dot decimals for bc and printf, whatever the user's locale.
export LC_ALL=C

DEST="$HOME/Library/Application Support/OrbitSim/Sources/earth"
MONTHS="07,12"
BMNG_FORMAT="tif"
ONLY="bmng,natural-earth,etopo,landsat"
SCENE="LC09_L1TP_016040_20221209_20230318_02_T1"
LANDSAT_AWS=0
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dest) DEST="$2"; shift 2 ;;
    --months) MONTHS="$2"; shift 2 ;;
    --bmng-format) BMNG_FORMAT="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --landsat-scene) SCENE="$2"; shift 2 ;;
    --landsat-aws) LANDSAT_AWS=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
    *) echo "fetch_planet_data.sh: unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
done
case "$BMNG_FORMAT" in tif|jpg) ;; *) echo "--bmng-format is tif or jpg" >&2; exit 2 ;; esac

wants() { case ",$ONLY," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

TODAY=$(date -u +%Y-%m-%d)
RECORDS="$DEST/.records"
TOTAL=0
MISSING=0
FETCHED=0
[ $DRY -eq 1 ] || mkdir -p "$RECORDS"

# The size a server reports for a URL (following redirects), empty if none.
# Only a final 200 counts: a 404 page's length, a timeout or no network
# give nothing (the caller reports the file NOT FOUND); never fails.
remote_size() {
  { curl -sIL --max-time 60 "$1" 2>/dev/null || true; } | tr -d '\r' | awk '
    toupper($1) ~ /^HTTP\// { status = $2; n = "" }
    tolower($1) == "content-length:" { n = $2 }
    END { if (status == "200" && n != "") print n }'
}

# What PlanetTiles changes in a file, for SOURCES.txt.
note_for() {
  case "$1" in
    bmng/*) echo "PlanetTiles paints the late-1950s Aral Sea and early-1960s Lake Chad (Natural Earth historic lakes) into this month's mosaic, in the colour of each lake's own 2004 water, before tiling it as JPEG." ;;
    landsat/*) echo "PlanetTiles pan-sharpens this scene to 15 m (Brovey), paints out the Shuttle Landing Facility (runway 15/33 and its overruns, tools/data/cape_paintout.json) by cloning scrub 500 m beside it, matches its colours to the BMNG month by a per-channel gain and offset, and feathers it into BMNG over 2 km at the inset's edge (28.30-28.85 N, 80.85-80.45 W)." ;;
    etopo/*) echo "PlanetTiles takes surface normals from these heights, flat over water." ;;
    natural-earth/*) echo "PlanetTiles rasterises the water (not land, lakes, and the historic Aral Sea and Lake Chad only)." ;;
  esac
}

# record PATH URL DATASET LICENCE CREDIT: the file's block for SOURCES.txt.
record() {
  local rel="$1" url="$2" dataset="$3" licence="$4" credit="$5"
  local file="$DEST/$rel" size sha
  size=$(stat -f %z "$file")
  sha=$(shasum -a 256 "$file" | awk '{print $1}')
  mkdir -p "$(dirname "$RECORDS/$rel")"
  {
    echo "$rel"
    echo "  Dataset: $dataset"
    echo "  URL: $url"
    echo "  Licence: $licence"
    echo "  Credit: $credit"
    echo "  Note: $(note_for "$rel")"
    echo "  Retrieved: $TODAY"
    echo "  Size: $size"
    echo "  sha256: $sha"
  } > "$RECORDS/$rel.txt"
}

# recorded_ok PATH: the file is there with the size and sha256 it was recorded with.
recorded_ok() {
  local rel="$1" file="$DEST/$1" rec="$RECORDS/$1.txt"
  [ -f "$file" ] && [ -f "$rec" ] || return 1
  local size sha
  size=$(awk '$1=="Size:" {print $2}' "$rec")
  sha=$(awk '$1=="sha256:" {print $2}' "$rec")
  [ "$(stat -f %z "$file")" = "$size" ] || return 1
  [ "$(shasum -a 256 "$file" | awk '{print $1}')" = "$sha" ]
}

# The files to fetch, in order: plan PATH URL DATASET LICENCE CREDIT.
P_REL=(); P_URL=(); P_DATASET=(); P_LICENCE=(); P_CREDIT=(); P_SIZE=()
plan() { P_REL+=("$1"); P_URL+=("$2"); P_DATASET+=("$3"); P_LICENCE+=("$4"); P_CREDIT+=("$5"); P_SIZE+=(""); }

# download I: fetch the planned file I (its size already asked) and record it.
download() {
  local i=$1
  local rel="${P_REL[$i]}" url="${P_URL[$i]}" expected="${P_SIZE[$i]}"
  local file="$DEST/$rel"
  # Checked when sizing.
  [ "$expected" = recorded ] && return
  mkdir -p "$(dirname "$file")"
  if [ ! -f "$file" ] || { [ -n "$expected" ] && [ "$(stat -f %z "$file")" != "$expected" ]; }; then
    echo "  $rel: fetching ($([ -n "$expected" ] && echo "$((expected / 1000000)) MB" || echo "size unknown"))"
    curl -fL --retry 3 --retry-delay 5 -C - -o "$file.partial" "$url"
    if [ -n "$expected" ] && [ "$(stat -f %z "$file.partial")" != "$expected" ]; then
      echo "  $rel: got $(stat -f %z "$file.partial") bytes, the server said $expected; run again to resume" >&2
      exit 1
    fi
    mv "$file.partial" "$file"
    FETCHED=$((FETCHED + 1))
  fi
  record "$rel" "$url" "${P_DATASET[$i]}" "${P_LICENCE[$i]}" "${P_CREDIT[$i]}"
  echo "  $rel: $(awk '$1=="sha256:" {print $2}' "$RECORDS/$rel.txt")"
}

# Free space (bytes) on the disk that holds DIR, or its nearest existing parent.
free_bytes() {
  local d="$1"
  while [ ! -d "$d" ]; do d=$(dirname "$d"); done
  df -Pk "$d" | awk 'NR==2 {print $4 * 1024}'
}

if [ $DRY -eq 1 ]; then echo "Dry run: sizes only. Destination: $DEST"; else echo "Destination: $DEST"; fi

# --- NASA Blue Marble Next Generation, 500 m (15"), monthly 2004 ------------
if wants bmng; then
  BMNG="https://assets.science.nasa.gov/content/dam/science/esd/eo/images/bmng/bmng-base"
  for m in $(echo "$MONTHS" | tr ',' ' '); do
    case "$m" in
      01) name=january ;; 02) name=february ;; 03) name=march ;; 04) name=april ;; 05) name=may ;; 06) name=june ;;
      07) name=july ;; 08) name=august ;; 09) name=september ;; 10) name=october ;; 11) name=november ;; 12) name=december ;;
      *) echo "--months: $m is not a two-digit month" >&2; exit 2 ;;
    esac
    for t in A1 A2 B1 B2 C1 C2 D1 D2; do
      case "$t" in
        A*) lon="180-90 W" ;; B*) lon="90-0 W" ;; C*) lon="0-90 E" ;; D*) lon="90-180 E" ;;
      esac
      case "$t" in *1) lat="90-0 N" ;; *2) lat="0-90 S" ;; esac
      if [ "$BMNG_FORMAT" = tif ]; then f="world.2004$m.3x21600x21600.${t}_geo.tif"; else f="world.2004$m.3x21600x21600.$t.jpg"; fi
      plan "bmng/$f" "$BMNG/$name/$f" \
        "NASA Blue Marble: Next Generation, base map (world), $name 2004, 500 m, tile $t ($lat, $lon)" \
        "Public domain (NASA imagery; NASA media usage guidelines)" \
        "NASA Earth Observatory (Reto Stöckli, NASA GSFC)"
    done
  done
fi

# --- Natural Earth 1:10m land, lakes and historic lakes ---------------------
if wants natural-earth; then
  NE="https://raw.githubusercontent.com/nvkelso/natural-earth-vector/ca96624a56bd078437bca8184e78163e5039ad19/geojson"
  for f in ne_10m_land ne_10m_lakes ne_10m_lakes_historic; do
    plan "natural-earth/$f.geojson" "$NE/$f.geojson" \
      "Natural Earth 1:10m physical vectors, $f (version 5.2.0-pre, commit ca96624)" \
      "Public domain (Natural Earth)" "Made with Natural Earth"
  done
fi

# --- NOAA ETOPO 2022 30" surface elevation ----------------------------------
if wants etopo; then
  f="ETOPO_2022_v1_30s_N90W180_surface.tif"
  plan "etopo/$f" "https://www.ngdc.noaa.gov/mgg/global/relief/ETOPO2022/data/30s/30s_surface_elev_gtif/$f" \
    "NOAA ETOPO 2022 Global Relief Model, 30 arc-second surface elevation (GeoTIFF)" \
    "Public domain (US Government work, NOAA NCEI)" \
    "NOAA National Centers for Environmental Information, 2022: ETOPO 2022 Global Relief Model, doi:10.25921/fd45-gt74"
fi

# --- Sizes first: what will come, and whether it fits ----------------------
NEEDED=0
for i in "${!P_REL[@]}"; do
  rel="${P_REL[$i]}"
  if [ $DRY -eq 0 ] && recorded_ok "$rel"; then
    printf '  %-58s  already here, sha256 checked\n' "$rel"
    P_SIZE[$i]=recorded
    continue
  fi
  size=$(remote_size "${P_URL[$i]}")
  P_SIZE[$i]="$size"
  if [ -z "$size" ]; then
    printf '  %-58s  NOT FOUND  %s\n' "$rel" "${P_URL[$i]}"
    MISSING=$((MISSING + 1))
    continue
  fi
  have=0
  [ -f "$DEST/$rel.partial" ] && have=$(stat -f %z "$DEST/$rel.partial")
  printf '  %-58s %8.1f MB  %s\n' "$rel" "$(echo "$size / 1000000" | bc -l)" "${P_URL[$i]}"
  TOTAL=$((TOTAL + size))
  NEEDED=$((NEEDED + size - have))
done
FREE=$(free_bytes "$DEST")
gb() { echo "$1 / 1000000000" | bc -l | xargs printf '%.2f'; }
echo "To download: $(gb $NEEDED) GB (of $(gb $TOTAL) GB listed; the Landsat scene, about 0.45 GB, comes by hand)."
echo "Free on that disk: $(gb $FREE) GB. Building the tiles afterwards needs up to 15 GB of scratch and about 3 GB for the tiles."
if [ $MISSING -gt 0 ]; then echo "$MISSING URL(s) not found: nothing fetched." >&2; exit 1; fi
if [ $DRY -eq 1 ]; then
  wants landsat && echo "Landsat $SCENE: B2, B3, B4, B8 and MTL from LandsatLook (USGS ERS sign-in) or, with --landsat-aws, s3://usgs-landsat."
  echo "Dry run: nothing downloaded."
  exit 0
fi
if [ "$FREE" -lt $((NEEDED + 500000000)) ]; then
  echo "Not enough space: $(gb $NEEDED) GB to download, $(gb $FREE) GB free. Nothing fetched." >&2
  exit 1
fi
if [ "$FREE" -lt $((NEEDED + 18000000000)) ]; then
  echo "Warning: after the download about $(gb $((FREE - NEEDED))) GB will be free; PlanetTiles earth all needs up to 18 GB." >&2
fi
for i in "${!P_REL[@]}"; do download "$i"; done

# --- Landsat 8/9 Collection 2 Level-1 scene of the Cape ---------------------
if wants landsat; then
  echo "Landsat scene $SCENE"
  year=$(echo "$SCENE" | cut -d_ -f4 | cut -c1-4)
  pr=$(echo "$SCENE" | cut -d_ -f3)
  key="collection02/level-1/standard/oli-tirs/$year/${pr:0:3}/${pr:3:3}/$SCENE"
  case "$SCENE" in LC09*) sat="Landsat 9" ;; *) sat="Landsat 8" ;; esac
  dataset="$sat OLI Collection 2 Level-1, scene $SCENE"
  licence="Public domain (USGS)"
  credit="$sat imagery courtesy of the U.S. Geological Survey"
  for b in B2 B3 B4 B8 MTL; do
    if [ $b = MTL ]; then f="${SCENE}_MTL.txt"; else f="${SCENE}_$b.TIF"; fi
    rel="landsat/$f"
    look="https://landsatlook.usgs.gov/data/$key/$f"
    if recorded_ok "$rel"; then echo "  $rel: already here, sha256 checked"; continue; fi
    mkdir -p "$DEST/landsat"
    if [ $LANDSAT_AWS -eq 1 ]; then
      aws s3 cp --request-payer requester "s3://usgs-landsat/$key/$f" "$DEST/$rel"
      record "$rel" "s3://usgs-landsat/$key/$f" "$dataset" "$licence" "$credit"
      echo "  $rel: $(awk '$1=="sha256:" {print $2}' "$RECORDS/$rel.txt")"
    elif [ -f "$DEST/$rel" ]; then
      record "$rel" "$look" "$dataset" "$licence" "$credit"
      echo "  $rel: found, recorded ($(awk '$1=="sha256:" {print $2}' "$RECORDS/$rel.txt"))"
    else
      echo "  $rel: download it while signed in to https://ers.cr.usgs.gov, from $look"
      MISSING=$((MISSING + 1))
    fi
  done
  if [ $DRY -eq 0 ] && [ $MISSING -gt 0 ] && [ $LANDSAT_AWS -eq 0 ]; then
    echo "  Put the files above in $DEST/landsat/ and run this again (or use --landsat-aws)."
  fi
fi

# SOURCES.txt from the records, in path order.
{
  echo "# Sources of OrbitSim's Earth tiles, written by tools/fetch_planet_data.sh on $TODAY."
  echo "# One block per file: its path here, then dataset, URL, licence, credit, date, size, sha256."
  find "$RECORDS" -name '*.txt' | LC_ALL=C sort | while read -r r; do cat "$r"; echo; done
} > "$DEST/SOURCES.txt"
echo "Wrote $DEST/SOURCES.txt ($FETCHED fetched this run)."
[ $MISSING -eq 0 ] || { echo "$MISSING file(s) still missing" >&2; exit 1; }
echo "Next: swift run -c release PlanetTiles earth all"

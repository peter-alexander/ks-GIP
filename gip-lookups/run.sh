#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_DIR="$SCRIPT_DIR/input"
BUILD_DIR="$SCRIPT_DIR/build"
ARCHIVE="$SCRIPT_DIR/D_lookuptabellen.zip"
SOURCE_URL="${GIP_LOOKUP_SOURCE_URL:-https://open.gip.gv.at/ogd/D_lookuptabellen.zip}"

rm -rf "$INPUT_DIR" "$BUILD_DIR"
mkdir -p "$INPUT_DIR" "$BUILD_DIR"

curl 	--fail 	--location 	--silent 	--show-error 	--retry 4 	--retry-delay 5 	--retry-all-errors 	--connect-timeout 30 	--max-time 180 	--output "$ARCHIVE" 	"$SOURCE_URL"

unzip -q -o "$ARCHIVE" -d "$INPUT_DIR"

mapfile -t csv_files < <(
	find "$INPUT_DIR" -type f -iname '*.csv' -print
)

if [ "${#csv_files[@]}" -lt 10 ]; then
	echo "Unplausibel wenige CSV-Dateien im GIP-Lookup-Archiv." >&2
	exit 1
fi

if [ "${#csv_files[@]}" -gt 0 ]; then
	first_dir="$(dirname "${csv_files[0]}")"

	if [ "$first_dir" != "$INPUT_DIR" ]; then
		tmp_dir="$SCRIPT_DIR/input-flat"
		rm -rf "$tmp_dir"
		mkdir -p "$tmp_dir"

		for file in "${csv_files[@]}"; do
			cp "$file" "$tmp_dir/$(basename "$file")"
		done

		rm -rf "$INPUT_DIR"
		mv "$tmp_dir" "$INPUT_DIR"
	fi
fi

node "$SCRIPT_DIR/build.mjs" 	"$INPUT_DIR" 	"$BUILD_DIR/GipLookups.json"

rm -f "$ARCHIVE"

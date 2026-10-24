#!/usr/bin/env bash
set -Eeuo pipefail

source <(sed '/^main "\$@"$/d' scripts/build-gip.sh)

main() {
	local gpkg_path
	local rfa_fields

	mkdir -p work dist/reference
	write_tippecanoe_filters
	validate_tippecanoe_filters
	validate_build_outputs

	download_file "$REFERENCE_URL" "$REFERENCE_ZIP"
	gpkg_path="$(extract_gpkg_from_zip "$REFERENCE_ZIP" "$REFERENCE_GPKG_NAME")"
	resolve_available_fields "$gpkg_path" BIKE_INFO rfa_fields "${RFA_FIELDS[@]}"
	convert_layer_to_geojson "$gpkg_path" BIKE_INFO work/rfa.geojson "$rfa_fields"
	rm -f "$gpkg_path"
	log_disk "after RFA source GPKG cleanup"

	if should_build_pmtiles; then
		build_pmtiles RFA work/rfa.geojson dist/reference/rfa.pmtiles GIP_BIKE 7 13 "$rfa_fields" --no-feature-limit --no-tile-size-limit
	fi
	if should_build_legacy_tiles; then
		build_legacy_tiles RFA work/rfa.geojson dist/reference/RFA GIP_BIKE 7 13 "$rfa_fields" --no-feature-limit --no-tile-size-limit
	fi

	rm -f work/rfa.geojson "$REFERENCE_ZIP"
	log_disk "reference build finished"
	find dist/reference -maxdepth 2 -type f -printf '%p\t%s bytes\n' | sort
}

main "$@"

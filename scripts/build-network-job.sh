#!/usr/bin/env bash
set -Eeuo pipefail

source <(sed '/^main "\$@"$/d' scripts/build-gip.sh)

main() {
	local gpkg_path
	local link_fields
	local link_speed_fields
	local einbahn_fields
	local linear_use_fields
	local einbahn_where_parts=()
	local einbahn_where

	mkdir -p work dist/network
	write_tippecanoe_filters
	validate_tippecanoe_filters
	validate_build_outputs

	download_file "$NETWORK_URL" "$NETWORK_ZIP"

	gpkg_path="$(extract_gpkg_from_zip "$NETWORK_ZIP" "$NETWORK_GPKG_NAME")"
	resolve_available_fields "$gpkg_path" LINK link_fields "${LINK_FIELDS[@]}"
	convert_layer_to_geojson "$gpkg_path" LINK work/link.geojson "$link_fields"
	rm -f "$gpkg_path"
	log_disk "after LINK source GPKG cleanup"

	if should_build_pmtiles; then
		build_pmtiles LINK work/link.geojson dist/network/link.pmtiles GIP_LINK 7 13 "$link_fields" --no-feature-limit --no-tile-size-limit -J "$LINK_FILTER_JSON"
	fi
	if should_build_legacy_tiles; then
		build_legacy_tiles LINK work/link.geojson dist/network/LINK GIP_LINK 7 13 "$link_fields" --no-feature-limit --no-tile-size-limit -J "$LINK_FILTER_JSON"
	fi
	rm -f work/link.geojson
	log_disk "after LINK cleanup"

	gpkg_path="$(extract_gpkg_from_zip "$NETWORK_ZIP" "$NETWORK_GPKG_NAME")"
	resolve_available_fields "$gpkg_path" LINK link_speed_fields "${LINK_SPEED_FIELDS[@]}"
	validate_required_any_field LINK_SPEED "$link_speed_fields" maxspeed_tow_car maxspeed_bkw_car
	convert_layer_to_geojson "$gpkg_path" LINK work/link-speed.geojson "$link_speed_fields"
	rm -f "$gpkg_path"
	log_disk "after LINK_SPEED source GPKG cleanup"

	if should_build_pmtiles; then
		build_pmtiles LINK_SPEED work/link-speed.geojson dist/network/link-speed.pmtiles GIP_LINK_SPEED 7 13 "$link_speed_fields" --no-feature-limit --no-tile-size-limit -J "$LINK_SPEED_FILTER_JSON"
	fi
	if should_build_legacy_tiles; then
		build_legacy_tiles LINK_SPEED work/link-speed.geojson dist/network/LINK-SPEED GIP_LINK_SPEED 7 13 "$link_speed_fields" --no-feature-limit --no-tile-size-limit -J "$LINK_SPEED_FILTER_JSON"
	fi
	rm -f work/link-speed.geojson
	log_disk "after LINK_SPEED cleanup"

	gpkg_path="$(extract_gpkg_from_zip "$NETWORK_ZIP" "$NETWORK_GPKG_NAME")"
	resolve_available_fields "$gpkg_path" LINK einbahn_fields "${EINBAHN_FIELDS[@]}"
	validate_required_any_field LINK_EINBAHN "$einbahn_fields" oneway_bike oneway_car
	if resolved_has_field "$einbahn_fields" oneway_bike; then
		einbahn_where_parts+=("oneway_bike IN (0, 1)")
	fi
	if resolved_has_field "$einbahn_fields" oneway_car; then
		einbahn_where_parts+=("oneway_car IN (0, 1)")
	fi
	einbahn_where="${einbahn_where_parts[0]}"
	if (( ${#einbahn_where_parts[@]} > 1 )); then
		einbahn_where+=" OR ${einbahn_where_parts[1]}"
	fi
	einbahn_where="(${einbahn_where})"
	if [[ -n "${EINBAHN_WHERE:-}" ]]; then
		einbahn_where="(${einbahn_where}) AND (${EINBAHN_WHERE})"
	fi
	convert_layer_to_geojson "$gpkg_path" LINK work/link-einbahn.geojson "$einbahn_fields" "$einbahn_where"
	log_einbahn_values "$gpkg_path" "$einbahn_where" "$einbahn_fields"
	rm -f "$gpkg_path"
	log_disk "after LINK_EINBAHN source GPKG cleanup"

	if should_build_pmtiles; then
		build_pmtiles LINK_EINBAHN work/link-einbahn.geojson dist/network/link-einbahn.pmtiles GIP_LINK_EINBAHN 7 13 "$einbahn_fields" --no-feature-limit --no-tile-size-limit -J "$LINK_EINBAHN_FILTER_JSON"
	fi
	if should_build_legacy_tiles; then
		build_legacy_tiles LINK_EINBAHN work/link-einbahn.geojson dist/network/LINK-EINBAHN GIP_LINK_EINBAHN 7 13 "$einbahn_fields" --no-feature-limit --no-tile-size-limit -J "$LINK_EINBAHN_FILTER_JSON"
	fi
	rm -f work/link-einbahn.geojson
	log_disk "after LINK_EINBAHN cleanup"

	gpkg_path="$(extract_gpkg_from_zip "$NETWORK_ZIP" "$NETWORK_GPKG_NAME")"
	resolve_excluding_fields "$gpkg_path" LINEAR_USE linear_use_fields
	convert_layer_to_geojson "$gpkg_path" LINEAR_USE work/linear-use.geojson "$linear_use_fields"
	rm -f "$gpkg_path"
	log_disk "after LINEAR_USE source GPKG cleanup"

	if should_build_pmtiles; then
		build_pmtiles LINEAR_USE work/linear-use.geojson dist/network/linear-use.pmtiles GIP_LINEAR_USE 7 13 "$linear_use_fields" --no-feature-limit --no-tile-size-limit
	fi
	if should_build_legacy_tiles; then
		build_legacy_tiles LINEAR_USE work/linear-use.geojson dist/network/LINEAR-USE GIP_LINEAR_USE 7 13 "$linear_use_fields" --no-feature-limit --no-tile-size-limit
	fi
	rm -f work/linear-use.geojson "$NETWORK_ZIP"
	log_disk "network build finished"
	find dist/network -maxdepth 2 -type f -printf '%p\t%s bytes\n' | sort
}

main "$@"

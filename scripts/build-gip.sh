#!/usr/bin/env bash
set -Eeuo pipefail

NETWORK_URL="https://open.gip.gv.at/ogd/B_gip_network_ogd.zip"
REFERENCE_URL="https://open.gip.gv.at/ogd/C_gip_reference_ogd.zip"
NETWORK_ZIP="work/B_gip_network_ogd.zip"
REFERENCE_ZIP="work/C_gip_reference_ogd.zip"
NETWORK_GPKG_NAME="gip_network_ogd.gpkg"
REFERENCE_GPKG_NAME="gip_reference_ogd.gpkg"
BUILD_VERSION="2026-07-v3"
LOCAL_FINGERPRINT_FILE="work/source-fingerprint.txt"
LINK_FILTER_JSON="work/link-filter.json"
LINK_SPEED_FILTER_JSON="work/link-speed-filter.json"
LINK_EINBAHN_FILTER_JSON="work/link-einbahn-filter.json"

STAGED_UPLOADS=()
FINAL_UPLOADS=()
CURL_RETRY_ARGS=(--ipv4 --connect-timeout 20 --retry 8 --retry-delay 20 --retry-all-errors)
SOURCE_HEAD_CURL_ARGS=(--ipv4 --connect-timeout 60 --retry 8 --retry-delay 20 --retry-all-errors)

LINK_FIELDS=(
	name_text_hr
	short_name_hr
	name_text_additional
	speed_tow_car
	speed_bkw_car
	maxspeed_tow_car
	maxspeed_bkw_car
	access_tow
	access_bkw
	functional_class
	lanes_tow_min
	lanes_tow_max
	lanes_bkw_min
	lanes_bkw_max
	form_of_way
	max_height
	max_width
	max_weight
	max_pressure
	urban
	toll
	construction_state
	oneway_car
	oneway_bike
	oneway_bus
	oneway_pedestrian
	edge_category
	regional_code
	sustainer
	owner
	subnet
	connector
	level_intermediate
)
LINK_SPEED_FIELDS=(
	maxspeed_tow_car
	maxspeed_bkw_car
	name_text_hr
	short_name_hr
	name_text_additional
)
EINBAHN_FIELDS=(
	oneway_bike
	oneway_car
)
RFA_FIELDS=(
	bike_feature_tow
	bike_feature_bkw
	surface
	owner
)

bool_is_true() {
	case "${1:-}" in
		true|TRUE|1|yes|YES|y|Y)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

should_build_pmtiles() {
	bool_is_true "${BUILD_PMTILES:-true}"
}

should_build_legacy_tiles() {
	bool_is_true "${BUILD_LEGACY_TILES:-false}"
}

validate_build_outputs() {
	if ! should_build_pmtiles && ! should_build_legacy_tiles; then
		echo "ERROR: At least one of BUILD_PMTILES or BUILD_LEGACY_TILES must be true." >&2
		exit 1
	fi

	echo "Build PMTiles: ${BUILD_PMTILES:-true}"
	echo "Build legacy PBF tiles: ${BUILD_LEGACY_TILES:-false}"
}

log_step() {
	echo
	echo "==> $*"
}

log_disk() {
	local label="$1"

	echo "::group::Disk usage: ${label}"
	df -h
	du -sh work out 2>/dev/null || true
	echo "::endgroup::"
}

cleanup_local() {
	rm -f "$NETWORK_ZIP" "$REFERENCE_ZIP"
	find work -type f \( \
		-name "$NETWORK_GPKG_NAME" \
		-o -name "$REFERENCE_GPKG_NAME" \
	\) -delete 2>/dev/null || true
	rm -f "$LINK_FILTER_JSON" "$LINK_SPEED_FILTER_JSON" "$LINK_EINBAHN_FILTER_JSON"
	rm -f "work/link.geojson" "work/link-speed.geojson" "work/link-einbahn.geojson" "work/linear-use.geojson" "work/rfa.geojson"
	rm -f "link.pmtiles" "link-speed.pmtiles" "link-einbahn.pmtiles" "linear-use.pmtiles" "rfa.pmtiles"
	rm -rf "LINK" "LINK-SPEED" "LINK-EINBAHN" "LINEAR-USE" "RFA"
}

on_error() {
	local exit_code=$?

	echo "ERROR: GIP build failed with exit code ${exit_code}." >&2
	cleanup_local || true
	log_disk "after failure cleanup"
	exit "$exit_code"
}

trap on_error ERR

read_head_fingerprint_fields() {
	local url="$1"
	local headers
	local fields

	echo "Reading HEAD metadata for ${url}" >&2
	headers="$(curl "${SOURCE_HEAD_CURL_ARGS[@]}" --fail --silent --show-error --location --head "$url" | tr -d '\r')"

	if ! fields="$(
		printf '%s\n' "$headers" | awk '
		BEGIN {
			last_modified = ""
			etag = ""
			content_length = ""
		}
		tolower($0) ~ /^last-modified:/ {
			last_modified = substr($0, index($0, ":") + 2)
		}
		tolower($0) ~ /^etag:/ {
			etag = substr($0, index($0, ":") + 2)
		}
		tolower($0) ~ /^content-length:/ {
			content_length = substr($0, index($0, ":") + 2)
		}
		END {
			printf "last-modified: %s\n", last_modified
			printf "etag: %s\n", etag
			printf "content-length: %s\n", content_length
			if (last_modified == "" || etag == "" || content_length == "") {
				exit 1
			}
		}
	'
	)"; then
		echo "ERROR: Incomplete HEAD metadata returned for ${url}." >&2
		return 1
	fi

	if [[ -z "$fields" ]]; then
		echo "ERROR: No usable HEAD metadata returned for ${url}." >&2
		return 1
	fi

	printf 'url: %s\n' "$url"
	printf '%s\n' "$fields"
}

calculate_build_config_hash() {
	sha256sum "$0" "$LINK_FILTER_JSON" "$LINK_SPEED_FILTER_JSON" "$LINK_EINBAHN_FILTER_JSON" |
		sha256sum |
		awk '{print $1}'
}

calculate_local_fingerprint() {
	local metadata
	local build_config_hash
	local network_metadata
	local reference_metadata

	build_config_hash="$(calculate_build_config_hash)"

	network_metadata="$(read_head_fingerprint_fields "$NETWORK_URL")" || {
		echo "ERROR: Could not read complete GIP fingerprint metadata for ${NETWORK_URL}." >&2
		return 1
	}
	reference_metadata="$(read_head_fingerprint_fields "$REFERENCE_URL")" || {
		echo "ERROR: Could not read complete GIP fingerprint metadata for ${REFERENCE_URL}." >&2
		return 1
	}

	metadata="$(
		printf '%s\n' "$network_metadata"
		printf '%s\n' "$reference_metadata"
		printf 'build-version: %s\n' "$BUILD_VERSION"
		printf 'build-config-sha256: %s\n' "$build_config_hash"
	)"

	echo "::group::Fingerprint metadata" >&2
	printf '%s\n' "$metadata" >&2
	echo "::endgroup::" >&2

	printf '%s\n' "$metadata" | sha256sum | awk '{print $1}'
}

load_remote_fingerprint() {
	curl "${CURL_RETRY_ARGS[@]}" --fail --silent --show-error --location "$PUBLIC_FINGERPRINT_URL" | tr -d '[:space:]'
}

download_file() {
	local url="$1"
	local target="$2"

	log_step "Downloading $(basename "$target")"
	log_disk "before download $(basename "$target")"
	curl "${CURL_RETRY_ARGS[@]}" --fail --location --output "$target" "$url"
	log_disk "after download $(basename "$target")"
}

extract_gpkg_from_zip() {
	local zip_file="$1"
	local expected_name="$2"
	local archive_member
	local gpkg_path

	log_step "Extracting ${expected_name} from $(basename "$zip_file")" >&2
	log_disk "before extracting ${expected_name}" >&2

	find work -type f -name "$expected_name" -delete 2>/dev/null || true
	archive_member="$(unzip -Z1 "$zip_file" | awk -v name="$expected_name" '$0 == name || $0 ~ ("/" name "$") { print; exit }')"
	if [[ -z "$archive_member" ]]; then
		echo "ERROR: ${expected_name} was not found in $(basename "$zip_file")." >&2
		unzip -Z1 "$zip_file" >&2
		return 1
	fi

	unzip -q -o "$zip_file" "$archive_member" -d work
	gpkg_path="$(find work -type f -name "$expected_name" -print -quit)"
	if [[ -z "$gpkg_path" ]]; then
		echo "ERROR: ${expected_name} was not found after extraction." >&2
		return 1
	fi

	log_disk "after extracting ${expected_name}" >&2
	printf '%s\n' "$gpkg_path"
}


join_by_comma() {
	local first=1
	local item

	for item in "$@"; do
		if (( first )); then
			printf '%s' "$item"
			first=0
		else
			printf ',%s' "$item"
		fi
	done
}

list_layer_fields() {
	local gpkg_path="$1"
	local layer="$2"

	ogrinfo -ro -so -json "$gpkg_path" "$layer" | jq -r '.layers[0].fields[].name'
}

is_excluded_property() {
	local field="$1"

	case "$field" in
		object_id|short_id|length|length_m|revision_id|offset_average|*_id|*_short_id)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

resolve_available_fields() {
	local gpkg_path="$1"
	local layer="$2"
	local target_array_name="$3"
	shift 3
	local requested=("$@")
	local available=()
	local selected=()
	local missing=()
	local field
	local requested_field
	local found

	mapfile -t available < <(list_layer_fields "$gpkg_path" "$layer")

	for requested_field in "${requested[@]}"; do
		found=0
		for field in "${available[@]}"; do
			if [[ "$field" == "$requested_field" ]]; then
				found=1
				break
			fi
		done
		if (( found )); then
			selected+=("$requested_field")
		else
			missing+=("$requested_field")
		fi
	done

	if (( ${#missing[@]} > 0 )); then
		echo "::warning::Layer ${layer} is missing requested fields: ${missing[*]}"
	fi
	if (( ${#selected[@]} == 0 )); then
		echo "ERROR: None of the requested fields exist in layer ${layer}." >&2
		return 1
	fi

	printf -v "$target_array_name" '%s
' "${selected[@]}"
}

resolve_excluding_fields() {
	local gpkg_path="$1"
	local layer="$2"
	local target_array_name="$3"
	local available=()
	local selected=()
	local field

	mapfile -t available < <(list_layer_fields "$gpkg_path" "$layer")

	for field in "${available[@]}"; do
		if is_excluded_property "$field"; then
			continue
		fi
		selected+=("$field")
	done

	if (( ${#selected[@]} == 0 )); then
		echo "ERROR: No fields remain for layer ${layer} after property filtering." >&2
		return 1
	fi

	printf -v "$target_array_name" '%s\n' "${selected[@]}"
}

resolved_has_field() {
	local resolved_fields="$1"
	local wanted="$2"

	grep -Fxq "$wanted" <<< "$resolved_fields"
}

validate_required_any_field() {
	local label="$1"
	local resolved_fields="$2"
	shift 2
	local field

	for field in "$@"; do
		if resolved_has_field "$resolved_fields" "$field"; then
			return 0
		fi
	done

	echo "ERROR: ${label} requires at least one of these fields: $*." >&2
	return 1
}

read_resolved_fields() {
	local resolved_fields="$1"

	printf '%s\n' "$resolved_fields"
}

tippecanoe_include_args() {
	local resolved_fields="$1"
	local field

	while IFS= read -r field; do
		[[ -n "$field" ]] || continue
		printf '%s\n' "-y"
		printf '%s\n' "$field"
	done < <(read_resolved_fields "$resolved_fields")
}

log_resolved_fields() {
	local label="$1"
	local resolved_fields="$2"

	echo "::group::Selected fields: ${label}"
	read_resolved_fields "$resolved_fields"
	echo "::endgroup::"
}

convert_layer_to_geojson() {
	local gpkg_path="$1"
	local layer="$2"
	local geojson_path="$3"
	local resolved_fields="$4"
	local where_clause="${5:-}"
	local fields=()
	local select_arg
	local ogr_args=()

	mapfile -t fields < <(read_resolved_fields "$resolved_fields")
	select_arg="$(join_by_comma "${fields[@]}")"

	log_step "Converting ${layer} to GeoJSON"
	log_resolved_fields "$layer" "$resolved_fields"
	log_disk "before ogr2ogr ${layer}"
	if [[ -n "$where_clause" ]]; then
		ogr_args=(-where "$where_clause")
	fi
	ogr2ogr -f GeoJSON "$geojson_path" "$gpkg_path" "$layer" -select "$select_arg" "${ogr_args[@]}"
	du -h "$geojson_path"
	log_disk "after ogr2ogr ${layer}"
}

build_pmtiles() {
	local label="$1"
	local geojson_path="$2"
	local pmtiles_path="$3"
	local layer_name="$4"
	local zoom_min="$5"
	local zoom_max="$6"
	local resolved_fields="$7"
	shift 7
	local include_args=()

	mapfile -t include_args < <(tippecanoe_include_args "$resolved_fields")

	log_step "Building ${label} PMTiles"
	log_disk "before ${label} PMTiles"
	tippecanoe -Z"$zoom_min" -z"$zoom_max" --force "$@" "${include_args[@]}" --layer="$layer_name" -o "./$pmtiles_path" "./$geojson_path"
	du -h "$pmtiles_path"
	log_disk "after ${label} PMTiles"
}

build_legacy_tiles() {
	local label="$1"
	local geojson_path="$2"
	local output_dir="$3"
	local layer_name="$4"
	local zoom_min="$5"
	local zoom_max="$6"
	local resolved_fields="$7"
	shift 7
	local include_args=()

	mapfile -t include_args < <(tippecanoe_include_args "$resolved_fields")

	log_step "Building ${label} legacy tiles"
	log_disk "before ${label} legacy"
	tippecanoe -Z"$zoom_min" -z"$zoom_max" --force "$@" "${include_args[@]}" --layer="$layer_name" -e "./$output_dir/" "./$geojson_path"
	du -sh "$output_dir"
	find "$output_dir" -type f | wc -l
	log_disk "after ${label} legacy"
}

write_tippecanoe_filters() {
	log_step "Writing Tippecanoe filters"
	mkdir -p work

	cat > "$LINK_FILTER_JSON" <<'EOF'
{
 "*": [
 "all",

 [
 "attribute-filter",
 "object_id",
 false
 ],
 [
 "attribute-filter",
 "short_id",
 false
 ],
 [
 "attribute-filter",
 "node_from_id",
 false
 ],
 [
 "attribute-filter",
 "node_from_short_id",
 false
 ],
 [
 "attribute-filter",
 "node_to_id",
 false
 ],
 [
 "attribute-filter",
 "node_to_short_id",
 false
 ],
 [
 "attribute-filter",
 "edge_id",
 false
 ],
 [
 "attribute-filter",
 "edge_short_id",
 false
 ],
 [
 "attribute-filter",
 "length",
 false
 ],

 [
 "attribute-filter",
 "sustainer",
 [">=", "$zoom", 12]
 ],
 [
 "attribute-filter",
 "regional_code",
 [">=", "$zoom", 12]
 ],
 [
 "attribute-filter",
 "connector",
 [">=", "$zoom", 12]
 ],
 [
 "attribute-filter",
 "max_width",
 [">=", "$zoom", 12]
 ],
 [
 "attribute-filter",
 "max_height",
 [">=", "$zoom", 12]
 ],
 [
 "attribute-filter",
 "max_pressure",
 [">=", "$zoom", 12]
 ],
 [
 "attribute-filter",
 "owner",
 [">=", "$zoom", 12]
 ],

 [
 "any",

 [">=", "$zoom", 13],

 [
 "all",
 [">=", "$zoom", 7],
 [
 "in",
 "functional_class",
 0,
 1,
 2,
 3,
 4,
 5,
 20
 ]
 ],

 [
 "all",
 [">=", "$zoom", 7],
 [
 "in",
 "edge_category",
 "A",
 "B",
 "BS",
 "H",
 "HA",
 "HB",
 "L",
 "LD",
 "LR",
 "LS",
 "P",
 "S",
 "SD",
 "SS"
 ]
 ],

 [
 "all",
 [">=", "$zoom", 10],
 ["==", "edge_category", "UR"]
 ],

 [
 "all",
 [">=", "$zoom", 11],
 [
 "in",
 "functional_class",
 21,
 31
 ]
 ],

 [
 "all",
 [">=", "$zoom", 12],
 [
 "in",
 "functional_class",
 6,
 22,
 25,
 103,
 106
 ]
 ]
 ]
 ]
}
EOF

	cat > "$LINK_SPEED_FILTER_JSON" <<'EOF'
{
 "*": [
 "all",

 [
 "attribute-filter",
 "maxspeed_tow_car",
 true
 ],
 [
 "attribute-filter",
 "maxspeed_bkw_car",
 true
 ],
 [
 "attribute-filter",
 "name_text_hr",
 true
 ],
 [
 "attribute-filter",
 "short_name_hr",
 true
 ],
 [
 "attribute-filter",
 "name_text_additional",
 true
 ],

 [
 "any",

 [
 "all",
 ["<", "$zoom", 10],
 [
 "any",
 [">=", "maxspeed_tow_car", 50],
 [">=", "maxspeed_bkw_car", 50]
 ]
 ],

 [
 "all",
 [">=", "$zoom", 10],
 [
 "any",
 [">=", "maxspeed_tow_car", 0],
 [">=", "maxspeed_bkw_car", 0]
 ]
 ]
 ]
 ]
}
EOF

	cat > "$LINK_EINBAHN_FILTER_JSON" <<'EOF'
{
 "*": [
 "all",

 [
 "attribute-filter",
 "oneway_bike",
 true
 ],
 [
 "attribute-filter",
 "oneway_car",
 true
 ],

 [
 "any",
 ["==", "oneway_bike", 0],
 ["==", "oneway_bike", 1],
 ["==", "oneway_car", 0],
 ["==", "oneway_car", 1]
 ]
 ]
}
EOF
}

validate_tippecanoe_filters() {
	local filter_file

	log_step "Validating Tippecanoe filter JSON"
	for filter_file in "$LINK_FILTER_JSON" "$LINK_SPEED_FILTER_JSON" "$LINK_EINBAHN_FILTER_JSON"; do
		jq -e . "$filter_file" >/dev/null
	done
	echo "Tippecanoe filter JSON is valid."
}


log_einbahn_values() {
	local gpkg_path="$1"
	local where_clause="$2"
	local resolved_fields="$3"
	local sql=""

	log_step "Inspecting EINBAHN oneway values"
	if resolved_has_field "$resolved_fields" oneway_car; then
		sql="SELECT 'oneway_car' AS field, oneway_car AS value, COUNT(*) AS count FROM LINK WHERE ${where_clause} GROUP BY oneway_car"
	fi
	if resolved_has_field "$resolved_fields" oneway_bike; then
		if [[ -n "$sql" ]]; then
			sql+=" UNION ALL "
		fi
		sql+="SELECT 'oneway_bike' AS field, oneway_bike AS value, COUNT(*) AS count FROM LINK WHERE ${where_clause} GROUP BY oneway_bike"
	fi
	if [[ -z "$sql" ]]; then
		echo "No oneway fields available for value logging."
		return 0
	fi

	if ! ogrinfo -ro -q -dialect SQLite -sql "$sql" "$gpkg_path"; then
		echo "Could not log EINBAHN oneway value summary; continuing."
	fi
}

require_upload_config() {
	if bool_is_true "${SKIP_UPLOAD:-false}"; then
		return 0
	fi

	local missing=()
	[[ -n "${FTP_HOST:-}" ]] || missing+=("FTP_HOST")
	[[ -n "${FTP_USER:-}" ]] || missing+=("FTP_USER")
	[[ -n "${FTP_PASS:-}" ]] || missing+=("FTP_PASS")
	[[ -n "${FTP_TARGET_DIR:-}" ]] || missing+=("FTP_TARGET_DIR")

	if (( ${#missing[@]} > 0 )); then
		printf 'ERROR: Missing upload configuration: %s\n' "${missing[*]}" >&2
		exit 1
	fi
}

validate_legacy_upload_parallel() {
	if [[ ! "${LEGACY_UPLOAD_PARALLEL:-4}" =~ ^[1-9][0-9]*$ ]]; then
		echo "ERROR: LEGACY_UPLOAD_PARALLEL must be a positive integer." >&2
		exit 1
	fi
	echo "Legacy upload parallelism: ${LEGACY_UPLOAD_PARALLEL:-4}"
}

remote_path() {
	local name="$1"
	local target_dir="${FTP_TARGET_DIR#/}"

	target_dir="${target_dir%/}"
	name="${name#/}"

	if [[ -n "$target_dir" ]]; then
		printf '%s/%s\n' "$target_dir" "$name"
	else
		printf '%s\n' "$name"
	fi
}

write_lftp_open() {
	local remote_url

	remote_url="${FTP_PROTOCOL:-ftp}://${FTP_HOST}"
	cat <<EOF
set cmd:fail-exit yes
set net:timeout ${LFTP_NET_TIMEOUT:-30}
set net:max-retries ${LFTP_RETRIES:-10}
set net:reconnect-interval-base ${LFTP_RETRY_DELAY:-30}
set net:reconnect-interval-multiplier 1
set ftp:passive-mode yes
set ftp:ssl-force ${LFTP_SSL_FORCE:-true}
set ssl:verify-certificate ${LFTP_SSL_VERIFY:-no}
set xfer:clobber yes
set mirror:set-permissions off
open "${remote_url}"
user "${FTP_USER}" "${FTP_PASS}"
EOF
}

curl_upload_file() {
	local local_path="$1"
	local target_name="$2"
	local target_path
	local target_url
	local curl_args

	if [[ "${FTP_PROTOCOL:-ftp}" != "ftp" ]]; then
		return 2
	fi

	target_path="$(remote_path "$target_name")"
	target_url="ftp://${FTP_HOST}/${target_path}"
	curl_args=(
		--fail
		--silent
		--show-error
		--ftp-ssl-reqd
		--ftp-pasv
		--ftp-create-dirs
		--connect-timeout "${FTP_CONNECT_TIMEOUT:-30}"
		--retry "${FTP_RETRIES:-10}"
		--retry-delay "${FTP_RETRY_DELAY:-30}"
		--retry-max-time "${FTP_RETRY_MAX_TIME:-900}"
		--retry-all-errors
		--user "${FTP_USER}:${FTP_PASS}"
		--upload-file "$local_path"
		"$target_url"
	)

	if [[ "${FTP_SSL_VERIFY:-no}" == "no" ]]; then
		curl_args+=(--insecure)
	fi

	curl "${curl_args[@]}"
}

remote_file_size_matches() {
	local local_path="$1"
	local target_name="$2"
	local target_path
	local target_url
	local local_size
	local headers
	local remote_size
	local curl_args

	if [[ "${FTP_PROTOCOL:-ftp}" != "ftp" ]]; then
		return 1
	fi

	target_path="$(remote_path "$target_name")"
	target_url="ftp://${FTP_HOST}/${target_path}"
	local_size="$(wc -c < "$local_path" | tr -d '[:space:]')"
	curl_args=(
		--fail
		--silent
		--show-error
		--ftp-ssl-reqd
		--ftp-pasv
		--connect-timeout "${FTP_CONNECT_TIMEOUT:-30}"
		--max-time "${FTP_SIZE_CHECK_MAX_TIME:-60}"
		--retry "${FTP_SIZE_CHECK_RETRIES:-2}"
		--retry-delay "${FTP_SIZE_CHECK_RETRY_DELAY:-10}"
		--retry-all-errors
		--user "${FTP_USER}:${FTP_PASS}"
		--head
		"$target_url"
	)

	if [[ "${FTP_SSL_VERIFY:-no}" == "no" ]]; then
		curl_args+=(--insecure)
	fi

	if ! headers="$(curl "${curl_args[@]}" | tr -d '\r')"; then
		echo "Remote size check failed for ${target_name}." >&2
		return 1
	fi

	remote_size="$(
		printf '%s\n' "$headers" |
			awk 'tolower($0) ~ /^content-length:/ { value = $2 } END { print value }'
	)"

	if [[ -z "$remote_size" ]]; then
		echo "Remote size check did not return Content-Length for ${target_name}." >&2
		return 1
	fi

	if [[ "$remote_size" == "$local_size" ]]; then
		echo "Remote size for ${target_name} matches local file (${local_size} bytes)."
		return 0
	fi

	echo "Remote size mismatch for ${target_name}: local ${local_size} bytes, remote ${remote_size} bytes." >&2
	return 1
}

upload_file_direct() {
	local local_path="$1"
	local target_name="$2"
	local curl_status

	if [[ "${FTP_PROTOCOL:-ftp}" == "ftp" ]]; then
		if curl_upload_file "$local_path" "$target_name"; then
			return 0
		else
			curl_status=$?
		fi

		echo "curl upload for ${target_name} failed with exit code ${curl_status}; checking remote size before failing." >&2
		if remote_file_size_matches "$local_path" "$target_name"; then
			return 0
		fi

		return "$curl_status"
	fi

	{
		write_lftp_open
		printf 'rm -f "%s"\n' "$(remote_path "$target_name")"
		printf 'put "%s" -o "%s"\n' "$local_path" "$(remote_path "$target_name")"
		printf 'bye\n'
	} | lftp
}

log_upload_file_info() {
	local local_path="$1"
	local target_name="$2"

	echo "Upload local path: ${local_path}"
	echo "Upload target name: ${target_name}"
	du -sh "$local_path"
}

log_upload_dir_info() {
	local local_path="$1"
	local target_name="$2"

	echo "Upload local path: ${local_path}"
	echo "Upload target name: ${target_name}"
	du -sh "$local_path"
	printf 'File count: '
	find "$local_path" -type f | wc -l
	echo "Legacy upload parallelism: ${LEGACY_UPLOAD_PARALLEL:-4}"
}

print_lftp_log_tail() {
	local log_file="$1"

	if [[ -f "$log_file" ]]; then
		echo "::group::Last lftp log lines: ${log_file}" >&2
		tail -n 100 "$log_file" >&2
		echo "::endgroup::" >&2
	fi
}

cleanup_remote_staging() {
	if bool_is_true "${SKIP_UPLOAD:-false}"; then
		return 0
	fi

	log_step "Cleaning old remote staging outputs"
	{
		write_lftp_open
		printf 'rm -f "%s"\n' "$(remote_path "link.pmtiles.new")"
		printf 'rm -f "%s"\n' "$(remote_path "link-speed.pmtiles.new")"
		printf 'rm -f "%s"\n' "$(remote_path "link-einbahn.pmtiles.new")"
		printf 'rm -f "%s"\n' "$(remote_path "linear-use.pmtiles.new")"
		printf 'rm -f "%s"\n' "$(remote_path "rfa.pmtiles.new")"
		printf 'rm -rf "%s"\n' "$(remote_path "LINK.new")"
		printf 'rm -rf "%s"\n' "$(remote_path "LINK-SPEED.new")"
		printf 'rm -rf "%s"\n' "$(remote_path "LINK-EINBAHN.new")"
		printf 'rm -rf "%s"\n' "$(remote_path "LINEAR-USE.new")"
		printf 'rm -rf "%s"\n' "$(remote_path "RFA.new")"
		printf 'bye\n'
	} | lftp
	echo "Remote staging cleanup complete."
}

upload_file_stage() {
	local local_path="$1"
	local final_name="$2"
	local staged_name="${final_name}.new"
	local start
	local duration

	if bool_is_true "${SKIP_UPLOAD:-false}"; then
		return 0
	fi

	log_step "Uploading staged file ${staged_name}"
	log_upload_file_info "$local_path" "$staged_name"
	log_disk "before upload ${staged_name}"
	start="$(date +%s)"
	upload_file_direct "$local_path" "$staged_name"
	duration="$(( $(date +%s) - start ))"
	STAGED_UPLOADS+=("$staged_name")
	FINAL_UPLOADS+=("$final_name")
	echo "Uploaded ${staged_name} successfully in ${duration}s."
	log_disk "after upload ${staged_name}"
}

upload_dir_direct() {
	local local_path="$1"
	local final_name="$2"
	local log_file="work/lftp-${final_name}.log"
	local start
	local duration

	if bool_is_true "${SKIP_UPLOAD:-false}"; then
		return 0
	fi

	log_step "Uploading legacy directory ${final_name}"
	log_upload_dir_info "$local_path" "$final_name"
	log_disk "before upload ${final_name}"
	rm -f "$log_file"
	start="$(date +%s)"
	if ! {
		write_lftp_open
		printf 'mirror --reverse --delete --continue --verbose=3 --log="%s" --parallel="%s" "%s" "%s"\n' "$log_file" "${LEGACY_UPLOAD_PARALLEL:-4}" "$local_path" "$(remote_path "$final_name")"
		printf 'bye\n'
	} | lftp; then
		print_lftp_log_tail "$log_file"
		return 1
	fi
	duration="$(( $(date +%s) - start ))"
	echo "Uploaded ${final_name} successfully in ${duration}s."
	log_disk "after upload ${final_name}"
}

finalize_uploads() {
	local index
	local final_name
	local staged_name
	local start
	local duration

	if bool_is_true "${SKIP_UPLOAD:-false}"; then
		echo "skip_upload=true; skipping remote finalization and fingerprint update."
		return 0
	fi

	log_step "Finalizing remote staged outputs"
	start="$(date +%s)"
	{
		write_lftp_open
		for index in "${!FINAL_UPLOADS[@]}"; do
			final_name="${FINAL_UPLOADS[$index]}"
			staged_name="${STAGED_UPLOADS[$index]}"
			printf 'rm -f "%s"\n' "$(remote_path "$final_name")"
			printf 'mv "%s" "%s"\n' "$(remote_path "$staged_name")" "$(remote_path "$final_name")"
		done
		printf 'bye\n'
	} | lftp
	upload_file_direct "$LOCAL_FINGERPRINT_FILE" "source-fingerprint.txt"
	duration="$(( $(date +%s) - start ))"
	echo "Finalized staged outputs and uploaded fingerprint successfully in ${duration}s."
	log_disk "after remote finalization"
}

build_network() {
	local gpkg_path
	local link_fields
	local link_speed_fields
	local einbahn_fields
	local linear_use_fields
	local einbahn_where_parts=()
	local einbahn_where

	download_file "$NETWORK_URL" "$NETWORK_ZIP"

	gpkg_path="$(extract_gpkg_from_zip "$NETWORK_ZIP" "$NETWORK_GPKG_NAME")"
	resolve_available_fields "$gpkg_path" "LINK" link_fields "${LINK_FIELDS[@]}"
	convert_layer_to_geojson "$gpkg_path" "LINK" "work/link.geojson" "$link_fields"
	rm -f "$gpkg_path"
	log_disk "after LINK source GPKG cleanup"

	if should_build_pmtiles; then
		build_pmtiles "LINK" "work/link.geojson" "link.pmtiles" "GIP_LINK" 7 13 "$link_fields" --no-feature-limit --no-tile-size-limit -J "$LINK_FILTER_JSON"
		upload_file_stage "link.pmtiles" "link.pmtiles"
		rm -f "link.pmtiles"
		log_disk "after local LINK PMTiles cleanup"
	fi

	if should_build_legacy_tiles; then
		build_legacy_tiles "LINK" "work/link.geojson" "LINK" "GIP_LINK" 7 13 "$link_fields" --no-feature-limit --no-tile-size-limit -J "$LINK_FILTER_JSON"
		upload_dir_direct "LINK" "LINK"
		rm -rf "LINK"
		log_disk "after local LINK legacy cleanup"
	fi
	rm -f "work/link.geojson"
	log_disk "after local LINK GeoJSON cleanup"

	gpkg_path="$(extract_gpkg_from_zip "$NETWORK_ZIP" "$NETWORK_GPKG_NAME")"
	resolve_available_fields "$gpkg_path" "LINK" link_speed_fields "${LINK_SPEED_FIELDS[@]}"
	validate_required_any_field "LINK_SPEED" "$link_speed_fields" maxspeed_tow_car maxspeed_bkw_car
	convert_layer_to_geojson "$gpkg_path" "LINK" "work/link-speed.geojson" "$link_speed_fields"
	rm -f "$gpkg_path"
	log_disk "after LINK_SPEED source GPKG cleanup"

	if should_build_pmtiles; then
		build_pmtiles "LINK_SPEED" "work/link-speed.geojson" "link-speed.pmtiles" "GIP_LINK_SPEED" 7 13 "$link_speed_fields" --no-feature-limit --no-tile-size-limit -J "$LINK_SPEED_FILTER_JSON"
		upload_file_stage "link-speed.pmtiles" "link-speed.pmtiles"
		rm -f "link-speed.pmtiles"
		log_disk "after local LINK_SPEED PMTiles cleanup"
	fi

	if should_build_legacy_tiles; then
		build_legacy_tiles "LINK_SPEED" "work/link-speed.geojson" "LINK-SPEED" "GIP_LINK_SPEED" 7 13 "$link_speed_fields" --no-feature-limit --no-tile-size-limit -J "$LINK_SPEED_FILTER_JSON"
		upload_dir_direct "LINK-SPEED" "LINK-SPEED"
		rm -rf "LINK-SPEED"
		log_disk "after local LINK_SPEED legacy cleanup"
	fi
	rm -f "work/link-speed.geojson"
	log_disk "after local LINK_SPEED GeoJSON cleanup"

	gpkg_path="$(extract_gpkg_from_zip "$NETWORK_ZIP" "$NETWORK_GPKG_NAME")"
	resolve_available_fields "$gpkg_path" "LINK" einbahn_fields "${EINBAHN_FIELDS[@]}"
	validate_required_any_field "LINK_EINBAHN" "$einbahn_fields" oneway_bike oneway_car
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
	convert_layer_to_geojson "$gpkg_path" "LINK" "work/link-einbahn.geojson" "$einbahn_fields" "$einbahn_where"
	log_einbahn_values "$gpkg_path" "$einbahn_where" "$einbahn_fields"
	rm -f "$gpkg_path"
	log_disk "after LINK_EINBAHN source GPKG cleanup"

	if should_build_pmtiles; then
		build_pmtiles "LINK_EINBAHN" "work/link-einbahn.geojson" "link-einbahn.pmtiles" "GIP_LINK_EINBAHN" 7 13 "$einbahn_fields" --no-feature-limit --no-tile-size-limit -J "$LINK_EINBAHN_FILTER_JSON"
		upload_file_stage "link-einbahn.pmtiles" "link-einbahn.pmtiles"
		rm -f "link-einbahn.pmtiles"
		log_disk "after local LINK_EINBAHN PMTiles cleanup"
	fi

	if should_build_legacy_tiles; then
		build_legacy_tiles "LINK_EINBAHN" "work/link-einbahn.geojson" "LINK-EINBAHN" "GIP_LINK_EINBAHN" 7 13 "$einbahn_fields" --no-feature-limit --no-tile-size-limit -J "$LINK_EINBAHN_FILTER_JSON"
		upload_dir_direct "LINK-EINBAHN" "LINK-EINBAHN"
		rm -rf "LINK-EINBAHN"
		log_disk "after local LINK_EINBAHN legacy cleanup"
	fi
	rm -f "work/link-einbahn.geojson"
	log_disk "after local LINK_EINBAHN GeoJSON cleanup"

	gpkg_path="$(extract_gpkg_from_zip "$NETWORK_ZIP" "$NETWORK_GPKG_NAME")"
	resolve_excluding_fields "$gpkg_path" "LINEAR_USE" linear_use_fields
	convert_layer_to_geojson "$gpkg_path" "LINEAR_USE" "work/linear-use.geojson" "$linear_use_fields"
	rm -f "$gpkg_path"
	log_disk "after LINEAR_USE source GPKG cleanup"

	if should_build_pmtiles; then
		build_pmtiles "LINEAR_USE" "work/linear-use.geojson" "linear-use.pmtiles" "GIP_LINEAR_USE" 7 13 "$linear_use_fields" --no-feature-limit --no-tile-size-limit
		upload_file_stage "linear-use.pmtiles" "linear-use.pmtiles"
		rm -f "linear-use.pmtiles"
		log_disk "after local LINEAR_USE PMTiles cleanup"
	fi

	if should_build_legacy_tiles; then
		build_legacy_tiles "LINEAR_USE" "work/linear-use.geojson" "LINEAR-USE" "GIP_LINEAR_USE" 7 13 "$linear_use_fields" --no-feature-limit --no-tile-size-limit
		upload_dir_direct "LINEAR-USE" "LINEAR-USE"
		rm -rf "LINEAR-USE"
		log_disk "after local LINEAR_USE legacy cleanup"
	fi
	rm -f "work/linear-use.geojson"
	log_disk "after local LINEAR_USE GeoJSON cleanup"

	rm -f "$NETWORK_ZIP"
	log_disk "after local network ZIP cleanup"
}

build_reference() {
	local gpkg_path
	local rfa_fields

	download_file "$REFERENCE_URL" "$REFERENCE_ZIP"
	gpkg_path="$(extract_gpkg_from_zip "$REFERENCE_ZIP" "$REFERENCE_GPKG_NAME")"
	resolve_available_fields "$gpkg_path" "BIKE_INFO" rfa_fields "${RFA_FIELDS[@]}"
	convert_layer_to_geojson "$gpkg_path" "BIKE_INFO" "work/rfa.geojson" "$rfa_fields"
	rm -f "$gpkg_path"
	log_disk "after RFA source GPKG cleanup"

	if should_build_pmtiles; then
		build_pmtiles "RFA" "work/rfa.geojson" "rfa.pmtiles" "GIP_BIKE" 7 13 "$rfa_fields" --no-feature-limit --no-tile-size-limit
		upload_file_stage "rfa.pmtiles" "rfa.pmtiles"
		rm -f "rfa.pmtiles"
		log_disk "after local RFA PMTiles cleanup"
	fi

	if should_build_legacy_tiles; then
		build_legacy_tiles "RFA" "work/rfa.geojson" "RFA" "GIP_BIKE" 7 13 "$rfa_fields" --no-feature-limit --no-tile-size-limit
		upload_dir_direct "RFA" "RFA"
		rm -rf "RFA"
		log_disk "after local RFA legacy cleanup"
	fi
	rm -f "work/rfa.geojson"
	log_disk "after local RFA GeoJSON cleanup"

	rm -f "$REFERENCE_ZIP"
	log_disk "after local reference ZIP cleanup"
}


main() {
	local local_fingerprint
	local remote_fingerprint=""

	mkdir -p work out
	log_disk "start"
	write_tippecanoe_filters
	validate_tippecanoe_filters
	validate_build_outputs

	local_fingerprint="$(calculate_local_fingerprint)"
	printf '%s\n' "$local_fingerprint" > "$LOCAL_FINGERPRINT_FILE"
	echo "Local GIP fingerprint: ${local_fingerprint}"
	log_disk "after local fingerprint"

	if [[ -n "${PUBLIC_FINGERPRINT_URL:-}" ]]; then
		remote_fingerprint="$(load_remote_fingerprint || true)"
		if [[ -n "$remote_fingerprint" ]]; then
			echo "Remote GIP fingerprint: ${remote_fingerprint}"
		else
			echo "Remote GIP fingerprint could not be loaded; treating source as changed."
		fi
		log_disk "after remote fingerprint"
	else
		echo "PUBLIC_FINGERPRINT_URL is not set; skipping remote fingerprint comparison."
		log_disk "after skipped remote fingerprint"
	fi

	if [[ -n "$remote_fingerprint" && "$remote_fingerprint" == "$local_fingerprint" ]] \
		&& ! bool_is_true "${FORCE_BUILD:-false}" \
		&& should_build_pmtiles \
		&& ! should_build_legacy_tiles; then
		echo "unchanged"
		log_disk "unchanged exit"
		rm -f "$LINK_FILTER_JSON" "$LINK_SPEED_FILTER_JSON" "$LINK_EINBAHN_FILTER_JSON"
		exit 0
	fi

	if bool_is_true "${FORCE_BUILD:-false}"; then
		echo "force_build=true; building even if the fingerprint is unchanged."
	else
		echo "changed; building"
	fi

	require_upload_config
	if should_build_legacy_tiles; then
		validate_legacy_upload_parallel
	fi
	cleanup_remote_staging
	build_network
	build_reference
	finalize_uploads
	cleanup_local
	log_disk "finished"
	echo "build complete"
}

main "$@"

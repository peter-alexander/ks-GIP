#!/usr/bin/env bash
set -Eeuo pipefail

source <(sed '/^main "\$@"$/d' scripts/build-gip.sh)

upload_pmtiles_if_present() {
	local path="$1"
	local name="$2"

	if [[ -f "$path" ]]; then
		upload_file_stage "$path" "$name"
	fi
}

upload_legacy_if_present() {
	local path="$1"
	local name="$2"

	if [[ -d "$path" ]]; then
		upload_dir_direct "$path" "$name"
	fi
}

main() {
	mkdir -p work
	printf '%s\n' "${GIP_FINGERPRINT:?GIP_FINGERPRINT is required}" > "$LOCAL_FINGERPRINT_FILE"

	require_upload_config
	cleanup_remote_staging

	upload_pmtiles_if_present dist/network/link.pmtiles link.pmtiles
	upload_pmtiles_if_present dist/network/link-speed.pmtiles link-speed.pmtiles
	upload_pmtiles_if_present dist/network/link-einbahn.pmtiles link-einbahn.pmtiles
	upload_pmtiles_if_present dist/network/linear-use.pmtiles linear-use.pmtiles
	upload_pmtiles_if_present dist/reference/rfa.pmtiles rfa.pmtiles

	upload_legacy_if_present dist/network/LINK LINK
	upload_legacy_if_present dist/network/LINK-SPEED LINK-SPEED
	upload_legacy_if_present dist/network/LINK-EINBAHN LINK-EINBAHN
	upload_legacy_if_present dist/network/LINEAR-USE LINEAR-USE
	upload_legacy_if_present dist/reference/RFA RFA

	finalize_uploads
}

main "$@"

#!/usr/bin/env bash
set -Eeuo pipefail

source <(sed '/^main "\$@"$/d' scripts/build-gip.sh)

calculate_build_config_hash() {
	sha256sum \
		scripts/build-gip.sh \
		scripts/check-gip.sh \
		scripts/build-network-job.sh \
		scripts/build-reference-job.sh \
		scripts/deploy-gip.sh \
		.github/workflows/publish.yml \
		"$LINK_FILTER_JSON" \
		"$LINK_SPEED_FILTER_JSON" \
		"$LINK_EINBAHN_FILTER_JSON" |
		sha256sum |
		awk '{print $1}'
}

load_remote_fingerprint_once() {
	curl \
		--fail \
		--silent \
		--show-error \
		--location \
		--connect-timeout 20 \
		--max-time 60 \
		"$PUBLIC_FINGERPRINT_URL" |
		tr -d '[:space:]'
}

main() {
	local local_fingerprint
	local remote_fingerprint=""
	local should_build="true"

	mkdir -p work
	write_tippecanoe_filters
	validate_tippecanoe_filters
	validate_build_outputs

	local_fingerprint="$(calculate_local_fingerprint)"
	printf '%s\n' "$local_fingerprint" > "$LOCAL_FINGERPRINT_FILE"
	echo "Local GIP fingerprint: ${local_fingerprint}"

	if [[ -n "${PUBLIC_FINGERPRINT_URL:-}" ]]; then
		remote_fingerprint="$(load_remote_fingerprint_once || true)"
		if [[ -n "$remote_fingerprint" ]]; then
			echo "Remote GIP fingerprint: ${remote_fingerprint}"
		else
			echo "Remote GIP fingerprint could not be loaded; treating source as changed."
		fi
	else
		echo "PUBLIC_FINGERPRINT_URL is not set; treating source as changed."
	fi

	if [[ -n "$remote_fingerprint" && "$remote_fingerprint" == "$local_fingerprint" ]] \
		&& ! bool_is_true "${FORCE_BUILD:-false}" \
		&& should_build_pmtiles \
		&& ! should_build_legacy_tiles; then
		should_build="false"
	fi

	if bool_is_true "${FORCE_BUILD:-false}"; then
		should_build="true"
		echo "force_build=true; build required."
	elif [[ "$should_build" == "true" ]]; then
		echo "changed; build required."
	else
		echo "unchanged; no build required."
	fi

	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		printf 'should_build=%s\n' "$should_build" >> "$GITHUB_OUTPUT"
		printf 'fingerprint=%s\n' "$local_fingerprint" >> "$GITHUB_OUTPUT"
	else
		printf 'should_build=%s\n' "$should_build"
		printf 'fingerprint=%s\n' "$local_fingerprint"
	fi
}

main "$@"

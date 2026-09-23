#!/usr/bin/env bash

NEP_STAGE_DIR=/usr/share/neteye/nep/
SETUP_LIBRARY=${NEP_STAGE_DIR}/setup/library
. ${SETUP_LIBRARY}/setup_scripts/get_arguments_from_command_line.sh

. /usr/share/neteye/scripts/rpm-functions.sh

function neteye_is_ocs_unsupported() {
    local version
    version=$(sed -n 's/^NetEye release \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' /etc/neteye-release)
    [[ -n "$version" ]] && [[ "$(printf '%s\n' "$version" "4.48" | sort -V | head -n1)" == "4.48" ]]
}

function remove_object_if_exists() {
    local type="$1"
    local name="$2"

    if icingacli director "$type" exist "$name" >/dev/null 2>&1; then
        icingacli director "$type" delete "$name"
    fi
}

if ! neteye_is_ocs_unsupported; then
    exit 0
fi

if [[ $neteye_deployment == 'single_node' ]]; then
    remove_object_if_exists serviceset "nx-ss-neteye-asset-state"
    remove_object_if_exists serviceset "nx-ss-neteye-asset-disk-state"
    remove_object_if_exists command "nx-c-check_inventory"
    exit 0
fi

if [[ $neteye_deployment == 'cluster' && $neteye_node_type == 'node' ]]; then
    SERVICE="icingaweb2"
    if is_active "$SERVICE"; then
        remove_object_if_exists serviceset "nx-ss-neteye-asset-state"
        remove_object_if_exists serviceset "nx-ss-neteye-asset-disk-state"
        remove_object_if_exists command "nx-c-check_inventory"
    else
        echo "[i] Inactive Cluster Node. Skipping."
    fi
    exit 0
fi

exit 0

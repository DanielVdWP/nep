#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"
PLUGIN="${REPO_ROOT}/nep/nep-dbms-hana/plugins/check_hana.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

mkdir -p "${TMP_DIR}/hdbclient" "${TMP_DIR}/plugins"
cat > "${TMP_DIR}/hdbclient/hdbclienv.sh" <<'EOF'
#!/bin/bash
EOF
chmod +x "${TMP_DIR}/hdbclient/hdbclienv.sh"

cat > "${TMP_DIR}/plugins/utils.sh" <<'EOF'
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3
EOF

cat > "${TMP_DIR}/hdbclient/hdbsql" <<'EOF'
#!/bin/bash
set -euo pipefail

input_file=
output_file=

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -I) input_file="$2"; shift 2 ;;
    -o) output_file="$2"; shift 2 ;;
    *) shift ;;
  esac
done

[[ -n "${input_file}" && -n "${output_file}" ]]

backup_type="$(sed -n "s/.*'\(complete data backup\|incremental data backup\|differential data backup\|data snapshot\|DATA_BACKUP\)' BACKUP_TYPE.*/\1/p" "${input_file}" | head -1)"

case "${backup_type}" in
  "complete data backup")
    result_type="complete data backup"
    ;;
  "incremental data backup")
    result_type="incremental data backup"
    ;;
  "differential data backup")
    result_type="differential data backup"
    ;;
  "data snapshot")
    result_type="data snapshot"
    ;;
  "DATA_BACKUP")
    result_type="complete data backup"
    ;;
  *)
    echo "Unexpected backup type in generated SQL: ${backup_type}" >&2
    exit 1
    ;;
esac

cat > "${output_file}" <<EOF_OUTPUT
"2026/09/23 12","any","any"," 123456","${result_type}","any","successful"," 1"," 0.00","AVG"," 1.00"," 100.00"," 1.00"," 0.10","any"
EOF_OUTPUT

printf '%s\n' "${backup_type}" > "${TMP_DIR}/captured-backup-type"
EOF
chmod +x "${TMP_DIR}/hdbclient/hdbsql"

export FAKE_HDBCLIENT="${TMP_DIR}/hdbclient"
export FAKE_PLUGIN_DIR="${TMP_DIR}/plugins"

# The production script uses fixed NetEye paths. Run it inside an isolated
# root-style layout so the real plugin and utilities are untouched.
mkdir -p /neteye/shared/monitoring/plugins/sap/hana
if [[ ! -e /neteye/shared/monitoring/plugins/sap/hana/hdbclient ]]; then
  ln -s "${FAKE_HDBCLIENT}" /neteye/shared/monitoring/plugins/sap/hana/hdbclient
  LINK_CREATED=1
else
  LINK_CREATED=0
fi

if [[ ! -e /usr/lib64/neteye/monitoring/plugins/utils.sh ]]; then
  mkdir -p /usr/lib64/neteye/monitoring/plugins
  ln -s "${TMP_DIR}/plugins/utils.sh" /usr/lib64/neteye/monitoring/plugins/utils.sh
  UTILS_LINK_CREATED=1
else
  UTILS_LINK_CREATED=0
fi

cleanup_neteye() {
  [[ "${LINK_CREATED}" == "1" ]] && rm -f /neteye/shared/monitoring/plugins/sap/hana/hdbclient
  [[ "${UTILS_LINK_CREATED}" == "1" ]] && rm -f /usr/lib64/neteye/monitoring/plugins/utils.sh
}
trap cleanup_neteye EXIT
assert_case() {
  local expected_type="$1"
  shift

  local output
  if ! output="$(env "$@" "${PLUGIN}" --function last_backup --sid HDB --host 127.0.0.1 --port 30013 --user SYSTEM --pass secret --lookback 3 2>&1)"; then
    echo "Plugin failed unexpectedly for backup type '${expected_type}'"
    printf '%s\n' "${output}"
    return 1
  fi

  local captured
  captured="$(cat "${TMP_DIR}/captured-backup-type")"
  [[ "${captured}" == "${expected_type}" ]] || {
    echo "Expected '${expected_type}', got '${captured}'"
    return 1
  }
  [[ "${output}" == OK\ -* ]] || {
    echo "Expected OK result, got:"
    printf '%s\n' "${output}"
    return 1
  }
}
assert_default() {
  local output
  if ! output="$(env HDBCLIENT="${FAKE_HDBCLIENT}" "${PLUGIN}" --function last_backup --sid HDB --host 127.0.0.1 --port 30013 --user SYSTEM --pass secret --lookback 3 2>&1)"; then
    echo "Default backup type failed"
    printf '%s\n' "${output}"
    return 1
  fi
  [[ "$(cat "${TMP_DIR}/captured-backup-type")" == "complete data backup" ]]
}

bash -n "${PLUGIN}" 
assert_default
assert_case "incremental data backup" env HDBCLIENT="${FAKE_HDBCLIENT}" --backup-type "incremental data backup"
assert_case "differential data backup" env HDBCLIENT="${FAKE_HDBCLIENT}" --backup-type "differential data backup"
assert_case "data snapshot" env HDBCLIENT="${FAKE_HDBCLIENT}" --backup-type "data snapshot"
assert_case "DATA_BACKUP" env HDBCLIENT="${FAKE_HDBCLIENT}" --backup-type DATA_BACKUP

echo "NEP-912 HANA last_backup plugin tests: OK"

#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECTS_CONFIG="${PROJECTS_CONFIG:-${SCRIPT_DIR}/projects.yaml}"

if [[ ! -f "${PROJECTS_CONFIG}" ]]; then
  echo "Error: Projects config file not found at ${PROJECTS_CONFIG}"
  echo "Please create it with the following keys: nextdr, source, target"
  exit 1
fi

parse_yaml_value() {
  local key=$1
  local file=$2
  local line
  line=$(grep -E "^[[:space:]]*${key}:" "${file}" | head -n1 || true)
  line=${line#*:}
  line=$(echo "${line}" | sed -E 's/[[:space:]]+#.*$//' | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//')
  line=$(echo "${line}" | sed -E "s/^['\"]?//; s/['\"]?\$//")
  echo "${line}"
}

NEXTDR_PROJECT=$(parse_yaml_value "nextdr" "${PROJECTS_CONFIG}")
SOURCE_PROJECT=$(parse_yaml_value "source" "${PROJECTS_CONFIG}")
TARGET_PROJECT=$(parse_yaml_value "target" "${PROJECTS_CONFIG}")

if [[ -z "${NEXTDR_PROJECT}" || -z "${SOURCE_PROJECT}" || -z "${TARGET_PROJECT}" ]]; then
  echo "Error: Missing project IDs in ${PROJECTS_CONFIG}. Ensure nextdr, source, and target are all set."
  exit 1
fi

PROJECTS=("${NEXTDR_PROJECT}" "${SOURCE_PROJECT}" "${TARGET_PROJECT}")

APIS=(
  compute.googleapis.com
  sql-component.googleapis.com
  sqladmin.googleapis.com
  cloudresourcemanager.googleapis.com
  iamcredentials.googleapis.com
)

for project in "${PROJECTS[@]}"; do
  echo ""
  echo "=== Enabling required APIs in project: ${project} ==="
  gcloud services enable "${APIS[@]}" --project="${project}" --quiet
  echo "✅ APIs enabled for ${project}"
done

echo ""
echo "API enablement completed."

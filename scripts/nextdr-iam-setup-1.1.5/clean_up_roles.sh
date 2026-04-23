#!/bin/bash

# Cleans up custom role bindings and service accounts created by add_custom_roles.sh.
# Removes IAM bindings for NextDR Backup/Restore and Service Account Token Creator,
# then deletes the service accounts in their respective projects.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECTS_CONFIG="${PROJECTS_CONFIG:-${SCRIPT_DIR}/projects.yaml}"

if [[ ! -f "${PROJECTS_CONFIG}" ]]; then
  echo "Error: Projects config file not found at ${PROJECTS_CONFIG}"
  exit 1
fi

if ! command -v gcloud >/dev/null 2>&1; then
  echo "Error: gcloud CLI is required. Install and authenticate before running this script."
  exit 1
fi

# Minimal YAML parser for simple key: value lines
parse_yaml_value() {
  local key=$1
  local file=$2
  local line
  line=$(grep -E "^[[:space:]]*${key}:" "${file}" | head -n1 || true)
  line=${line#*:}
  line=$(echo "${line}" | sed -E 's/[[:space:]]+#.*$//' | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//')
  line=$(echo "${line}" | sed -E 's/^["'\'']?//; s/["'\'']?$//')
  echo "${line}"
}

NEXTDR_PROJECT=$(parse_yaml_value "nextdr" "${PROJECTS_CONFIG}")
SOURCE_PROJECT=$(parse_yaml_value "source" "${PROJECTS_CONFIG}")
TARGET_PROJECT=$(parse_yaml_value "target" "${PROJECTS_CONFIG}")
NEXTDR_SA_ID=$(parse_yaml_value "nextdr_service_account" "${PROJECTS_CONFIG}")
COMPUTE_INSTANCE_SA_ID=$(parse_yaml_value "compute_instance_service_account" "${PROJECTS_CONFIG}")
BACKUP_ROLE_ID=$(parse_yaml_value "backup_role_id" "${PROJECTS_CONFIG}")
RESTORE_ROLE_ID=$(parse_yaml_value "restore_role_id" "${PROJECTS_CONFIG}")

if [[ -z "${NEXTDR_PROJECT}" || -z "${SOURCE_PROJECT}" || -z "${TARGET_PROJECT}" ]]; then
  echo "Error: Missing project IDs in ${PROJECTS_CONFIG}. Ensure nextdr, source, and target are all set."
  exit 1
fi

SERVICE_ACCOUNT_ID="${SERVICE_ACCOUNT_ID:-nextdr-service}"

BACKUP_ROLE_ID="${BACKUP_ROLE_ID:-nextdr_backup}"
RESTORE_ROLE_ID="${RESTORE_ROLE_ID:-nextdr_restore}"

build_sa_email() {
  local sa_id=$1
  local project_id=$2

  if [[ "${sa_id}" == *"@"* ]]; then
    echo "${sa_id}"
  else
    echo "${sa_id}@${project_id}.iam.gserviceaccount.com"
  fi
}

remove_role_binding() {
  local project_id=$1
  local sa_email=$2
  local role=$3

  echo "Removing role '${role}' from '${sa_email}' in project '${project_id}'..."
  if ! gcloud projects remove-iam-policy-binding "${project_id}" \
    --member="serviceAccount:${sa_email}" \
    --role="${role}" \
    --quiet >/dev/null 2>&1; then
    echo "  Skipped (binding may not exist)."
  fi
}

remove_custom_role_binding() {
  local project_id=$1
  local sa_email=$2
  local role_id=$3
  remove_role_binding "${project_id}" "${sa_email}" "projects/${project_id}/roles/${role_id}"
}

delete_service_account() {
  local project_id=$1
  local sa_id=$2
  local sa_email
  sa_email="$(build_sa_email "${sa_id}" "${project_id}")"

  echo "Deleting service account '${sa_email}' from project '${project_id}'..."
  if gcloud iam service-accounts describe "${sa_email}" --project="${project_id}" >/dev/null 2>&1; then
    gcloud iam service-accounts delete "${sa_email}" --project="${project_id}" --quiet
  else
    echo "  Skipped (service account not found)."
  fi
}

echo "Starting cleanup using config: ${PROJECTS_CONFIG}"

# --- Remove role bindings ---
NEXTDR_SA_EMAIL="$(build_sa_email "${NEXTDR_SA_ID:-${SERVICE_ACCOUNT_ID}}" "${NEXTDR_PROJECT}")"

remove_custom_role_binding "${SOURCE_PROJECT}" "${NEXTDR_SA_EMAIL}" "${BACKUP_ROLE_ID}"
remove_custom_role_binding "${TARGET_PROJECT}" "${NEXTDR_SA_EMAIL}" "${BACKUP_ROLE_ID}"
remove_custom_role_binding "${TARGET_PROJECT}" "${NEXTDR_SA_EMAIL}" "${RESTORE_ROLE_ID}"

echo "Removing Backup, Restore, and Token Creator roles from nextdr_service_account in nextdr project..."
remove_custom_role_binding "${NEXTDR_PROJECT}" "${NEXTDR_SA_EMAIL}" "${BACKUP_ROLE_ID}"
remove_custom_role_binding "${NEXTDR_PROJECT}" "${NEXTDR_SA_EMAIL}" "${RESTORE_ROLE_ID}"
remove_role_binding "${NEXTDR_PROJECT}" "${NEXTDR_SA_EMAIL}" "roles/iam.serviceAccountTokenCreator"

if [[ -n "${COMPUTE_INSTANCE_SA_ID}" ]]; then
  echo "Removing Service Account Token Creator from compute instance service account..."
  COMPUTE_INSTANCE_SA_EMAIL="$(build_sa_email "${COMPUTE_INSTANCE_SA_ID}" "${SOURCE_PROJECT}")"
  remove_role_binding "${SOURCE_PROJECT}" "${COMPUTE_INSTANCE_SA_EMAIL}" "roles/iam.serviceAccountTokenCreator"
  remove_role_binding "${TARGET_PROJECT}" "${COMPUTE_INSTANCE_SA_EMAIL}" "roles/iam.serviceAccountTokenCreator"
  remove_role_binding "${NEXTDR_PROJECT}" "${COMPUTE_INSTANCE_SA_EMAIL}" "roles/iam.serviceAccountTokenCreator"
fi

# --- Delete service accounts ---
delete_service_account "${NEXTDR_PROJECT}" "${NEXTDR_SA_ID:-${SERVICE_ACCOUNT_ID}}"

echo "Cleanup completed."

#!/bin/bash

# This script creates or updates two custom IAM roles for NextDR using the gcloud CLI.
# It is idempotent, meaning it can be run multiple times without causing errors.

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECTS_CONFIG="${PROJECTS_CONFIG:-${SCRIPT_DIR}/projects.yaml}"

if [[ ! -f "${PROJECTS_CONFIG}" ]]; then
  echo "Error: Projects config file not found at ${PROJECTS_CONFIG}"
  echo "Please create it with the following keys: nextdr, source, target"
  echo "Example:"
  cat <<'EOF'
nextdr: my-nextdr-project
source: my-source-project
target: my-target-project
EOF
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
  line=$(echo "${line}" | sed -E "s/^['\"]?//; s/['\"]?\$//")
  echo "${line}"
}

NEXTDR_PROJECT=$(parse_yaml_value "nextdr" "${PROJECTS_CONFIG}")
SOURCE_PROJECT=$(parse_yaml_value "source" "${PROJECTS_CONFIG}")
TARGET_PROJECT=$(parse_yaml_value "target" "${PROJECTS_CONFIG}")
NEXTDR_SA_ID=$(parse_yaml_value "nextdr_service_account" "${PROJECTS_CONFIG}")
#COMPUTE_INSTANCE_SA_ID=$(parse_yaml_value "compute_instance_service_account" "${PROJECTS_CONFIG}")

if [[ -z "${NEXTDR_PROJECT}" || -z "${SOURCE_PROJECT}" || -z "${TARGET_PROJECT}" ]]; then
  echo "Error: Missing project IDs in ${PROJECTS_CONFIG}. Ensure nextdr, source, and target are all set."
  exit 1
fi

PROJECTS=("${NEXTDR_PROJECT}" "${SOURCE_PROJECT}" "${TARGET_PROJECT}")
echo "Using projects: ${PROJECTS[*]}"

SERVICE_ACCOUNT_ID="${SERVICE_ACCOUNT_ID:-nextdr-service}"
SERVICE_ACCOUNT_DISPLAY_NAME="${SERVICE_ACCOUNT_DISPLAY_NAME:-NextDR Service Account}"

# --- Role Definitions ---
# Using temporary YAML files for role definitions is a clean and declarative way
# to manage permissions with the gcloud CLI.

# 1. NextDR Backup Role
BACKUP_ROLE_ID="nextdr_backup"
# Create a temporary file to hold the role definition
BACKUP_ROLE_FILE=$(mktemp)
# Write the role definition to the temporary file
cat > "${BACKUP_ROLE_FILE}" << EOL
title: "NextDR Backup Role"
description: "Grants permissions required for NextDR to perform backup operations on GCP resources."
stage: "BETA"
includedPermissions:
- compute.disks.get
- compute.disks.list
- compute.disks.createSnapshot
- compute.snapshots.get
- compute.snapshots.create
- compute.snapshots.list
- compute.snapshots.useReadOnly
- compute.snapshots.getIamPolicy
- compute.snapshots.setIamPolicy
- compute.snapshots.delete
- compute.instances.get
- compute.instances.list
- compute.projects.get
- compute.zoneOperations.get
- compute.globalOperations.get  
- storage.buckets.get
- storage.buckets.list
- storage.buckets.getIamPolicy 
- storage.objects.get
- storage.objects.list
- storage.buckets.create
- resourcemanager.projects.getIamPolicy
- cloudsql.instances.list
- cloudsql.instances.get
- cloudsql.backupRuns.create
- cloudsql.backupRuns.list
- cloudsql.databases.list
- cloudsql.instances.export
- resourcemanager.projects.get
- serviceusage.services.list
- compute.networks.list
- compute.subnetworks.list
- compute.firewalls.list
- compute.routes.list
EOL

# 2. NextDR Restore Role
RESTORE_ROLE_ID="nextdr_restore"
# Create a temporary file to hold the role definition
RESTORE_ROLE_FILE=$(mktemp)
# Write the role definition to the temporary file
cat > "${RESTORE_ROLE_FILE}" << EOL
title: "NextDR Restore Role"
description: "Grants permissions required for NextDR to restore GCP resources from backups."
stage: "BETA"
includedPermissions:
- resourcemanager.projects.get  # To read basic project metadata.
- serviceusage.services.list    # To verify that necessary APIs are enabled before starting a restore.
- compute.projects.get          # To get project-level Compute Engine information.
- compute.zoneOperations.get    # To check the status of ongoing operations like creating a disk or a VM.
- resourcemanager.projects.setIamPolicy   # To apply a backed-up IAM policy to the project.



#Compute Engine (VMs, Disks, Snapshots)

- compute.snapshots.get         # To find an existing snapshot.
- compute.snapshots.create
- compute.snapshots.delete
- compute.snapshots.list        # To list available snapshots.
- compute.snapshots.useReadOnly # To use a snapshot as a source for a new disk.
- compute.disks.create          # To create a new persistent disk from a snapshot.
- compute.disks.setLabels
- compute.disks.use
- compute.disks.delete          # To delete a disk. ( Kamlesh, need to ask Avi why we need this on target )
- compute.instances.create      # To create a new VM instance.
- compute.instances.attachDisk  # To attach the newly created disk to the VM instance.
- compute.instances.setMetadata # To apply original metadata to the restored instance.
- compute.instances.setTags     # To apply original network tags to the restored instance.
- compute.networks.list         # To list available networks for VM placement.
- compute.subnetworks.useExternalIp
- compute.subnetworks.list      # To list available subnetworks for VM placement.
- compute.subnetworks.use

# Cloud SQL

- cloudsql.instances.list       # To list existing instances, which may be the restore target.
- cloudsql.instances.get        # view details of a specific instance.
- cloudsql.backupRuns.list      # To find the specific backup you want to restore from.
- cloudsql.instances.restoreBackup  # To initiate a restore from a backup run to an instance.
- cloudsql.instances.import     # To restore from a SQL dump file located in Cloud Storage.
- cloudsql.instances.update     # To make configuration changes to the instance after the restore.
- cloudsql.instances.create     # Create instance
- cloudsql.databases.create
- cloudsql.databases.list 

# Cloud Storage

- storage.buckets.get           # To locate the bucket containing backups.
- storage.buckets.list          # To access the bucket containing backups.
- storage.objects.get           # To read a specific backup object (file) from the bucket.
- storage.objects.list          # To list all backup objects (files) in the bucket.
- storage.buckets.create
- storage.buckets.setIamPolicy
EOL




# --- Function to Create or Update a Role ---
create_or_update_role() {
  local role_id=$1
  local project_id=$2
  local role_file=$3

  echo ""
  echo "Processing role: ${role_id}..."

  # Check if the role already exists in the project
  if gcloud iam roles describe "${role_id}" --project="${project_id}" &> /dev/null; then
    echo "Role '${role_id}' already exists. Updating to ensure permissions are correct..."
    gcloud iam roles update "${role_id}" \
      --project="${project_id}" \
      --file="${role_file}" \
      --quiet
    echo "✅ Successfully updated role: ${role_id}"
  else
    echo "Role '${role_id}' does not exist. Creating..."
    gcloud iam roles create "${role_id}" \
      --project="${project_id}" \
      --file="${role_file}" \
      --quiet
    echo "✅ Successfully created role: ${role_id}"
  fi
}

create_service_account() {
  local project_id=$1
  local sa_id=$2
  local sa_display_name=$3

  local sa_email="${sa_id}@${project_id}.iam.gserviceaccount.com"

  echo ""
  echo "Processing service account: ${sa_email}..."

  if gcloud iam service-accounts describe "${sa_email}" --project="${project_id}" &> /dev/null; then
    echo "Service account '${sa_email}' already exists. Skipping creation."
  else
    gcloud iam service-accounts create "${sa_id}" \
      --project="${project_id}" \
      --display-name="${sa_display_name}" \
      --quiet
    echo "✅ Successfully created service account: ${sa_email}"
  fi
}

grant_role_to_service_account() {
  local project_id=$1
  local sa_email=$2
  local role_id=$3

  echo "Granting role '${role_id}' to '${sa_email}' in project '${project_id}'..."
  gcloud projects add-iam-policy-binding "${project_id}" \
    --member="serviceAccount:${sa_email}" \
    --role="projects/${project_id}/roles/${role_id}" \
    --quiet
}

grant_service_account_token_creator() {
  local project_id=$1
  local sa_email=$2

  echo "Granting Service Account Token Creator to '${sa_email}' in project '${project_id}'..."
  gcloud projects add-iam-policy-binding "${project_id}" \
    --member="serviceAccount:${sa_email}" \
    --role="roles/iam.serviceAccountTokenCreator" \
    --quiet
}

build_sa_email() {
  local sa_id=$1
  local project_id=$2

  if [[ "${sa_id}" == *"@"* ]]; then
    echo "${sa_id}"
  else
    echo "${sa_id}@${project_id}.iam.gserviceaccount.com"
  fi
}

# --- Execute and Cleanup ---
# The 'trap' command ensures that the temporary files are deleted when the script exits,
# whether it succeeds or fails.
trap 'rm -f "${BACKUP_ROLE_FILE}" "${RESTORE_ROLE_FILE}"' EXIT

for project in "${PROJECTS[@]}"; do
  echo ""
  echo "=== Processing project: ${project} ==="
  create_or_update_role "${BACKUP_ROLE_ID}" "${project}" "${BACKUP_ROLE_FILE}"
  create_or_update_role "${RESTORE_ROLE_ID}" "${project}" "${RESTORE_ROLE_FILE}"
done

echo ""
echo "Ensuring NextDR service account exists in nextdr project..."
create_service_account "${NEXTDR_PROJECT}" "${NEXTDR_SA_ID:-${SERVICE_ACCOUNT_ID}}" "${SERVICE_ACCOUNT_DISPLAY_NAME}"

echo ""
echo "Assigning NextDR Backup Role to nextdr_service_account in source project..."
NEXTDR_SA_EMAIL="$(build_sa_email "${NEXTDR_SA_ID:-${SERVICE_ACCOUNT_ID}}" "${NEXTDR_PROJECT}")"
grant_role_to_service_account "${SOURCE_PROJECT}" "${NEXTDR_SA_EMAIL}" "${BACKUP_ROLE_ID}"

echo ""
echo "Assigning NextDR Backup and Restore Roles to nextdr_service_account in nextdr and target projects..."
grant_role_to_service_account "${NEXTDR_PROJECT}" "${NEXTDR_SA_EMAIL}" "${BACKUP_ROLE_ID}"
grant_role_to_service_account "${NEXTDR_PROJECT}" "${NEXTDR_SA_EMAIL}" "${RESTORE_ROLE_ID}"
grant_role_to_service_account "${TARGET_PROJECT}" "${NEXTDR_SA_EMAIL}" "${BACKUP_ROLE_ID}"
grant_role_to_service_account "${TARGET_PROJECT}" "${NEXTDR_SA_EMAIL}" "${RESTORE_ROLE_ID}"

echo ""
echo "Assigning Backup, Restore, and Token Creator roles to nextdr_service_account in nextdr project..."
grant_role_to_service_account "${NEXTDR_PROJECT}" "${NEXTDR_SA_EMAIL}" "${BACKUP_ROLE_ID}"
grant_role_to_service_account "${NEXTDR_PROJECT}" "${NEXTDR_SA_EMAIL}" "${RESTORE_ROLE_ID}"
grant_service_account_token_creator "${NEXTDR_PROJECT}" "${NEXTDR_SA_EMAIL}"

#if [[ -n "${COMPUTE_INSTANCE_SA_ID}" ]]; then
#  echo ""
#  echo "Assigning Service Account Token Creator to compute instance service account in source project..."
#  COMPUTE_INSTANCE_SA_EMAIL="$(build_sa_email "${COMPUTE_INSTANCE_SA_ID}" "${SOURCE_PROJECT}")"
#  grant_service_account_token_creator "${SOURCE_PROJECT}" "${COMPUTE_INSTANCE_SA_EMAIL}"
#  grant_service_account_token_creator "${TARGET_PROJECT}" "${COMPUTE_INSTANCE_SA_EMAIL}"
#  grant_service_account_token_creator "${NEXTDR_PROJECT}" "${COMPUTE_INSTANCE_SA_EMAIL}"
#else
#  echo ""
#  echo "No compute_instance_service_account specified in ${PROJECTS_CONFIG}; skipping token binding."
#fi

echo ""
echo "Script finished."

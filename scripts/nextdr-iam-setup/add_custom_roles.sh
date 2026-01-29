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
SOURCE_SA_ID=$(parse_yaml_value "source_service_account" "${PROJECTS_CONFIG}")
TARGET_SA_ID=$(parse_yaml_value "target_service_account" "${PROJECTS_CONFIG}")
BACKUP_ROLE_ID=$(parse_yaml_value "backup_role_id" "${PROJECTS_CONFIG}")
RESTORE_ROLE_ID=$(parse_yaml_value "restore_role_id" "${PROJECTS_CONFIG}")
#COMPUTE_INSTANCE_SA_ID=$(parse_yaml_value "compute_instance_service_account" "${PROJECTS_CONFIG}")

if [[ -z "${NEXTDR_PROJECT}" || -z "${SOURCE_PROJECT}" || -z "${TARGET_PROJECT}" ]]; then
  echo "Error: Missing project IDs in ${PROJECTS_CONFIG}. Ensure nextdr, source, and target are all set."
  exit 1
fi

PROJECTS=("${NEXTDR_PROJECT}" "${SOURCE_PROJECT}" "${TARGET_PROJECT}")
echo "Using projects: ${PROJECTS[*]}"

SERVICE_ACCOUNT_ID="${SERVICE_ACCOUNT_ID:-nextdr-service}"
SERVICE_ACCOUNT_DISPLAY_NAME="${SERVICE_ACCOUNT_DISPLAY_NAME:-NextDR Service Account}"
SOURCE_SERVICE_ACCOUNT_DISPLAY_NAME="${SOURCE_SERVICE_ACCOUNT_DISPLAY_NAME:-NextDR Source Service Account}"
TARGET_SERVICE_ACCOUNT_DISPLAY_NAME="${TARGET_SERVICE_ACCOUNT_DISPLAY_NAME:-NextDR Target Service Account}"

# --- Role Definitions ---
# Using temporary YAML files for role definitions is a clean and declarative way
# to manage permissions with the gcloud CLI.

BACKUP_ROLE_ID="${BACKUP_ROLE_ID:-nextdr_backup}"
RESTORE_ROLE_ID="${RESTORE_ROLE_ID:-nextdr_restore}"

role_title_sa_id_for_project() {
  local project_id=$1

  if [[ "${project_id}" == "${NEXTDR_PROJECT}" ]]; then
    echo "${NEXTDR_SA_ID:-${SERVICE_ACCOUNT_ID}}"
    return
  fi

  if [[ "${project_id}" == "${SOURCE_PROJECT}" && -n "${SOURCE_SA_ID}" ]]; then
    echo "${SOURCE_SA_ID}"
    return
  fi

  if [[ "${project_id}" == "${TARGET_PROJECT}" && -n "${TARGET_SA_ID}" ]]; then
    echo "${TARGET_SA_ID}"
    return
  fi

  echo "${NEXTDR_SA_ID:-${SERVICE_ACCOUNT_ID}}"
}

write_backup_role_file() {
  local role_file=$1
  local sa_id=$2

  cat > "${role_file}" << EOL
title: "NextDR Backup Role (${sa_id})"
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
- storage.buckets.setIamPolicy
- storage.buckets.update
- resourcemanager.projects.getIamPolicy
- resourcemanager.projects.get
- cloudsql.instances.list
- cloudsql.instances.get
- cloudsql.backupRuns.create
- cloudsql.backupRuns.list
- cloudsql.databases.list
- cloudsql.instances.export
- serviceusage.services.list
- compute.networks.list
- compute.subnetworks.list
- compute.firewalls.list
- compute.routes.list
- backupdr.backupPlanAssociations.createForCloudSqlInstance
- backupdr.backupPlanAssociations.deleteForCloudSqlInstance
- backupdr.backupPlanAssociations.fetchForCloudSqlInstance
- backupdr.backupPlanAssociations.getForCloudSqlInstance
- backupdr.backupPlanAssociations.triggerBackupForCloudSqlInstance
- backupdr.backupPlans.get
- backupdr.backupPlans.list
- backupdr.backupPlans.useForCloudSqlInstance
- backupdr.backupVaults.get
- backupdr.backupVaults.list
- compute.disks.get
- compute.disks.getIamPolicy
- compute.disks.list
- compute.disks.useReadOnly
- compute.instances.get
- compute.projects.get
- compute.snapshots.create
- compute.snapshots.get
- compute.snapshots.list
- compute.snapshots.setIamPolicy
- compute.snapshots.useReadOnly
- storagetransfer.agentpools.create
- storagetransfer.agentpools.delete
- storagetransfer.agentpools.get
- storagetransfer.agentpools.list
- storagetransfer.agentpools.update
- storagetransfer.jobs.create
- storagetransfer.jobs.delete
- storagetransfer.jobs.get
- storagetransfer.jobs.list
- storagetransfer.jobs.run
- storagetransfer.jobs.update
- storagetransfer.operations.cancel
- storagetransfer.operations.get
- storagetransfer.operations.list
- storagetransfer.operations.pause
- storagetransfer.operations.resume
- storagetransfer.projects.getServiceAccount
EOL
}

write_restore_role_file() {
  local role_file=$1
  local sa_id=$2

  cat > "${role_file}" << EOL
title: "NextDR Restore Role (${sa_id})"
description: "Grants permissions required for NextDR to restore GCP resources from backups."
stage: "BETA"
includedPermissions:
- resourcemanager.projects.get  # To read basic project metadata.
- serviceusage.services.list    # To verify that necessary APIs are enabled before starting a restore.

- resourcemanager.projects.setIamPolicy   # To apply a backed-up IAM policy to the project.



#Compute Engine (VMs, Disks, Snapshots)

- compute.projects.get          # To get project-level Compute Engine information.
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
- compute.zoneOperations.get    # To check the status of ongoing operations like creating a disk or a VM.

# VPC networks + peering
- compute.networks.create
- compute.networks.delete
- compute.networks.get
- compute.networks.list
- compute.networks.update
- compute.networks.use
- compute.networks.addPeering
- compute.networks.removePeering
- compute.networks.updatePeering
- compute.networks.listPeeringRoutes

# Subnets (incl. flow logs/private access via update)
- compute.subnetworks.create
- compute.subnetworks.delete
- compute.subnetworks.get
- compute.subnetworks.list
- compute.subnetworks.update
- compute.subnetworks.use
- compute.subnetworks.setPrivateIpGoogleAccess

# Routes
- compute.routes.create
- compute.routes.delete
- compute.routes.get
- compute.routes.list

# Cloud Router / NAT
- compute.routers.create
- compute.routers.delete
- compute.routers.get
- compute.routers.list
- compute.routers.update
- compute.routers.use

# Static external IPs (regional)
- compute.addresses.create
- compute.addresses.delete
- compute.addresses.get
- compute.addresses.list
- compute.addresses.use

# Firewalls (NOTE: read-only in networkAdmin)
- compute.firewalls.get
- compute.firewalls.list


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


# Service Networking (private services access style connections)
- servicenetworking.operations.get
- servicenetworking.services.addPeering
- servicenetworking.services.deleteConnection
- servicenetworking.services.get
- servicenetworking.services.listPeeredDnsDomains
- servicenetworking.services.createPeeredDnsDomain
- servicenetworking.services.deletePeeredDnsDomain

# Cloud Storage

- storage.buckets.get           # To locate the bucket containing backups.
- storage.buckets.list          # To access the bucket containing backups.
- storage.objects.get           # To read a specific backup object (file) from the bucket.
- storage.objects.list          # To list all backup objects (files) in the bucket.
- storage.buckets.create
- storage.buckets.setIamPolicy
EOL
}


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


ensure_target_vpc_peering() {
  local project_id=$1
  local range_name=""
  local existing_range_names=""

  echo ""
  echo "Enabling Service Networking API in target project '${project_id}'..."
  gcloud services enable servicenetworking.googleapis.com \
    --project="${project_id}"

  echo ""
  echo "Ensuring allocated IP range exists in target project '${project_id}'..."
  existing_range_names=$(gcloud compute addresses list \
    --global \
    --project="${project_id}" \
    --filter="purpose=VPC_PEERING AND network=default" \
    --format="value(name)")

  if gcloud compute addresses describe google-managed-services-default \
    --global \
    --project="${project_id}" &> /dev/null; then
    range_name="google-managed-services-default"
    echo "Allocated IP range '${range_name}' already exists."
  elif [[ -n "${existing_range_names}" ]]; then
    range_name=$(echo "${existing_range_names}" | head -n1)
    echo "Using existing allocated IP range '${range_name}'."
  else
    range_name="google-managed-services-default"
    gcloud compute addresses create "${range_name}" \
      --global \
      --purpose=VPC_PEERING \
      --prefix-length=16 \
      --network=default \
      --project="${project_id}"
  fi

  echo ""
  echo "Ensuring VPC peering is connected in target project '${project_id}'..."
  if gcloud services vpc-peerings list \
    --network=default \
    --project="${project_id}" \
    --format="value(service)" | grep -q "^servicenetworking.googleapis.com$"; then
    echo "VPC peering for Service Networking already connected."
  else
    if gcloud services vpc-peerings connect \
      --service=servicenetworking.googleapis.com \
      --network=default \
      --ranges="${range_name}" \
      --project="${project_id}"; then
      echo "VPC peering for Service Networking connected."
    else
      local existing_peer_ranges=""
      existing_peer_ranges=$(gcloud services vpc-peerings list \
        --network=default \
        --project="${project_id}" \
        --filter="service:servicenetworking.googleapis.com" \
        --format="value(reservedPeeringRanges)")
      if [[ -z "${existing_peer_ranges}" ]]; then
        existing_peer_ranges="${range_name}"
      fi
      echo "CreateConnection failed; attempting UpdateConnection with ranges: ${existing_peer_ranges}"
      gcloud services vpc-peerings update \
        --service=servicenetworking.googleapis.com \
        --network=default \
        --ranges="${existing_peer_ranges}" \
        --project="${project_id}"
    fi
  fi

  echo ""
  echo "Current VPC peerings in target project '${project_id}':"
  gcloud services vpc-peerings list \
    --network=default \
    --project="${project_id}"
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

for project in "${PROJECTS[@]}"; do
  echo ""
  echo "=== Processing project: ${project} ==="
  ROLE_SA_ID="$(role_title_sa_id_for_project "${project}")"
  BACKUP_ROLE_FILE=$(mktemp)
  RESTORE_ROLE_FILE=$(mktemp)
  write_backup_role_file "${BACKUP_ROLE_FILE}" "${ROLE_SA_ID}"
  write_restore_role_file "${RESTORE_ROLE_FILE}" "${ROLE_SA_ID}"
  create_or_update_role "${BACKUP_ROLE_ID}" "${project}" "${BACKUP_ROLE_FILE}"
  create_or_update_role "${RESTORE_ROLE_ID}" "${project}" "${RESTORE_ROLE_FILE}"
  rm -f "${BACKUP_ROLE_FILE}" "${RESTORE_ROLE_FILE}"
done

echo ""
echo "Ensuring NextDR service account exists in nextdr project..."
create_service_account "${NEXTDR_PROJECT}" "${NEXTDR_SA_ID:-${SERVICE_ACCOUNT_ID}}" "${SERVICE_ACCOUNT_DISPLAY_NAME}"

if [[ -n "${SOURCE_SA_ID}" ]]; then
  echo ""
  echo "Ensuring service account exists in source project..."
  create_service_account "${SOURCE_PROJECT}" "${SOURCE_SA_ID}" "${SOURCE_SERVICE_ACCOUNT_DISPLAY_NAME}"
fi

if [[ -n "${TARGET_SA_ID}" ]]; then
  echo ""
  echo "Ensuring service account exists in target project..."
  create_service_account "${TARGET_PROJECT}" "${TARGET_SA_ID}" "${TARGET_SERVICE_ACCOUNT_DISPLAY_NAME}"
fi

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

echo ""
if [[ "${ENABLE_VPC_PEERING:-0}" == "1" ]]; then
  echo "Setting up Service Networking peering in target project..."
  ensure_target_vpc_peering "${TARGET_PROJECT}"
else
  echo "Skipping Service Networking peering (enable with --with-vpc-peering)."
fi

echo ""
echo "Script finished."

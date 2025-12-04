Download helper scripts

1. curl -L -o nextdrinstall.zip https://github.com/nextdrai/nextdrinstall/archive/refs/heads/main.zip
2. unzip nextdrinstall.zip
3. cd nextdrinstall-main/scripts/nextdr-iam-setup


This utility creates or updates the NextDR custom IAM roles and binds them to the right service accounts in three GCP projects.

How run.sh works
- Wrapper around add_custom_roles.sh so you do not have to set environment variables manually.
- Reads a YAML config (projects.yaml by default) and exports PROJECTS_CONFIG before calling add_custom_roles.sh.
- Exits on first failure (set -e) so fix any error before rerunning.

How projects.yaml is used
- Required keys: nextdr, source, target (GCP project IDs).
- Required service accounts: nextdr_service_account, source_service_account, target_service_account (service account IDs; the script adds @<project>.iam.gserviceaccount.com unless you include the domain).
- Required: compute_instance_service_account to grant Service Account Token Creator bindings across projects.


Steps to run
1) Update projects.yaml with your project IDs, service account IDs, and compute instance service account ID.
2) Authenticate with gcloud using an account that can create custom roles and update IAM policy bindings:
      gcloud auth login
3) Run the wrapper (uses projects.yaml by default):
      bash run.sh
  

Notes
- The script is idempotent: rerunning updates roles/bindings instead of failing when they already exist.

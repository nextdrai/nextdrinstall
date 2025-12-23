Download helper scripts

1. curl -L -o nextdrinstall.zip https://github.com/nextdrai/nextdrinstall/archive/refs/heads/main.zip
2. unzip nextdrinstall.zip
3. cd nextdrinstall-main/scripts/nextdr-iam-setup


This utility enables the required GCP APIs, creates the needed service accounts, then creates or updates the NextDR custom IAM roles and binds them to the right service accounts in three GCP projects.

How run.sh works
- Enables the following APIs across your nextdr, source, and target projects by calling enable_apis.sh:
    * Compute Engine API (compute.googleapis.com)
    * Cloud SQL API (sql-component.googleapis.com)
    * Cloud SQL Admin API (sqladmin.googleapis.com)
    * Cloud Resource Manager API (cloudresourcemanager.googleapis.com)
    * IAM Service Account Credentials API (iamcredentials.googleapis.com)
- Reads a YAML config (projects.yaml by default) and exports PROJECTS_CONFIG before calling the helper scripts.
- Exits on first failure (set -e) so fix any error before rerunning.

How projects.yaml is used
- Required keys: nextdr, source, target (GCP project IDs).
- Required service account: nextdr_service_account (service account ID; the script adds @<project>.iam.gserviceaccount.com unless you include the domain).


Steps to run
1) Update projects.yaml with your project IDs, NextDR service account ID
2) Authenticate with gcloud using an account that can create custom roles and update IAM policy bindings:
      gcloud auth login
3) Run the wrapper (uses projects.yaml by default):
      bash run.sh
  

Notes
- The script is idempotent: rerunning updates roles/bindings instead of failing when they already exist.

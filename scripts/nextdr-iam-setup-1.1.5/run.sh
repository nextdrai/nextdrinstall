
#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECTS_CONFIG="${PROJECTS_CONFIG:-${SCRIPT_DIR}/projects.yaml}"
ENABLE_VPC_PEERING=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-vpc-peering)
      ENABLE_VPC_PEERING=1
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Usage: run.sh [--with-vpc-peering]

Options:
  --with-vpc-peering   Run Service Networking VPC peering setup in target project.
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Use --help for usage."
      exit 1
      ;;
  esac
done

echo "Enabling required APIs..."
PROJECTS_CONFIG="${PROJECTS_CONFIG}" bash "${SCRIPT_DIR}/enable_apis.sh"

echo ""
echo "Creating and binding custom roles..."
PROJECTS_CONFIG="${PROJECTS_CONFIG}" ENABLE_VPC_PEERING="${ENABLE_VPC_PEERING}" \
  bash "${SCRIPT_DIR}/add_custom_roles.sh"

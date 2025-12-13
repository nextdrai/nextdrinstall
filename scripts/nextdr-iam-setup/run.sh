
#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECTS_CONFIG="${PROJECTS_CONFIG:-${SCRIPT_DIR}/projects.yaml}"

echo "Enabling required APIs..."
PROJECTS_CONFIG="${PROJECTS_CONFIG}" bash "${SCRIPT_DIR}/enable_apis.sh"

echo ""
echo "Creating and binding custom roles..."
PROJECTS_CONFIG="${PROJECTS_CONFIG}" bash "${SCRIPT_DIR}/add_custom_roles.sh"

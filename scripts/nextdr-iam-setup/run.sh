
#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECTS_CONFIG="${PROJECTS_CONFIG:-${SCRIPT_DIR}/projects.yaml}"

PROJECTS_CONFIG="${PROJECTS_CONFIG}" bash "${SCRIPT_DIR}/add_custom_roles.sh"

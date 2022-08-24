#!/bin/bash

set -euo pipefail

#
# This script enables maintenance mode in the given Kubernetes namespace.
# Note that the script is only able to enable maintenance, not disable it. To disable maintenance, run a full
# deploy.
#

if [[ $# != 1 ]]; then
  echo "Expected 1 arguments - NAMESPACE, got $#"
  exit 1
fi

NAMESPACE="$1"

# Import functions
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
source "$DIR/common.sh"

enable_maintenance "$NAMESPACE"
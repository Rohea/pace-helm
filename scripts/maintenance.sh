#!/bin/bash

set -euo pipefail

#
# This script enables maintenance mode in the given Kubernetes namespace.
# Note that the script is only able to enable maintenance, not disable it. To disable maintenance, run a full
# deploy.
#

usage() {
  echo "Usage: maintenance.sh enable|disable NAMESPACE"
  exit 1
}

if [[ $# != 2 ]]; then
  echo "Expected 2 arguments, got $#"
  usage
fi

OP="$1"
NAMESPACE="$2"

# Import functions
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
source "$DIR/common.sh"

if [[ $OP == 'enable' ]]; then
  maintenance_enable "$NAMESPACE"
elif [[ $OP == 'disable' ]]; then
  maintenance_disable "$NAMESPACE"
else
  echo "Unknown operation: \"${OP}\""
  usage
fi

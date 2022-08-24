#!/bin/bash

#
# Common Kubernetes functions
#
# This file is meant to be imported via 'source'. It does not actually do anything, only defines functions.
#

######################################################################################################################################################

#
# Wait for all stop-during-deploy components of a Pace deployment to be scaled to zero (i.e. to have no running pods)
#
# This function only waits, does not actually do any scaling down. It will block until there are no pods with the label
#   rohea.com/stop-during-deploy='true'
# The function will never exit, there is no timeout.
#
# Args:
#   $1: Kubernetes namespace where to wait for the pods to scale down
#
wait_for_zero_scale() {
  _ns="$1"

  while true; do
    echo "Checking whether all deployments have been scaled down"
    pods_output=$(kubectl -n "$_ns" get pods -l rohea.com/app=pace -l rohea.com/stop-during-deploy='true')

    pods_count_incl_header=$(echo "$pods_output" | wc -l)
    echo "  Number of pods still to terminate: $(( pods_count_incl_header - 1))"

    if [[ $pods_count_incl_header -eq 1 ]]; then
      echo "  Deployments have been scaled down."
      break
    else
      echo "  Deployments have not yet been scaled down. Re-checking in 5 seconds..."
    fi

    sleep 5
  done
}

#
# Enable maintenance mode for a k8s Pace deployment
#
# Args:
#   $1: Kubernetes namespace where to enable the maintenance mode
#
enable_maintenance() {
  _ns="$1"

  if ! kubectl -n "$_ns" get deployment maintenance-page >/dev/null; then
    echo "There is no deployment named 'maintenance-page' in the namespace '$_ns'. Cannot enable maintenance mode!"
    return 1
  fi

  echo "Deployment 'maintenance-page' found in namespace '$_ns'"

  ingresses_names=$(kubectl -n "$_ns" get ingresses.v1.networking.k8s.io --no-headers -o custom-columns=":metadata.name" --selector pace.rohea.com/component=pace-ingress)
  if [[ -z "$ingresses_names" ]]; then
    echo "No applicable Ingress resources found to patch. Scaling down the deployment but there will not be a nice maintenance frontpage."
  else
    echo "Patching the following Ingress resources to point to the maintenance page:"
    for ing in $ingresses_names; do
      echo "  - '$ing'"
    done
  fi

  # Scale up maintenance page, redirect ingresses to it
  kubectl -n "$_ns" scale deployment/maintenance-page --replicas=1
  sleep 30

  for ingress_name in $ingresses_names; do
    echo "Patching ingress: '$ingress_name'"
    kubectl -n "$_ns" patch ingresses.v1.networking.k8s.io "$ingress_name" --type=json \
            -p='[{"op": "replace", "path": "/spec/rules/0/http/paths/0/backend/service/name", "value":"maintenance-page"}]'
  done

  echo "Ingress resources patched"

  echo "Will scale down the following deployments:"
  deployments_to_scale_down=$(kubectl -n "$_ns" get deployment -l rohea.com/stop-during-deploy='true' --no-headers -o custom-columns=":metadata.name")
  for d in $deployments_to_scale_down; do
    echo "  - '${d}'"
  done

  kubectl -n "$_ns" scale deployment -l rohea.com/stop-during-deploy='true' --replicas 0
  wait_for_zero_scale "$_ns"
}
#!/bin/bash

set -euo pipefail

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

  iteration_idx=1
  while true; do
    echo "Checking whether all deployments have been scaled down"
    pods_output=$(kubectl -n "$_ns" get pods -l rohea.com/app=pace,rohea.com/stop-during-deploy='true')

    pods_count_incl_header=$(echo "$pods_output" | wc -l)
    echo "  Number of pods still to terminate: $(( pods_count_incl_header - 1))"

    if [[ $pods_count_incl_header -eq 1 ]]; then
      echo "  Deployments have been scaled down."
      break
    else
      echo "  Deployments have not yet been scaled down. Re-checking in 5 seconds..."
    fi

    if [[ $(( iteration_idx % 10 )) == 0 ]]; then
      echo "This is poll iteration #${iteration_idx}, showing kubernetes events in the namespace:"
      kubectl -n "$_ns" get event --sort-by=lastTimestamp | sed 's/^/|  |  /g'
    fi

    iteration_idx=$(( iteration_idx + 1 ))

    sleep 5
  done
}

wait_for_rollout() {
  _ns="$1"
  shift
  _deployments=("$@")

  # 10 minutes to roll out the deployments should be enough, even taking into account the waiting time for cluster
  # resources to free up (other deployments getting torn down). We do not want to wait too long.
  # Note that this does not include the time for migrations to finish.
  _rollout_timeout="${DEPLOY_ROLLOUT_TIMEOUT:-600}"

  echo "Checking whether all deployments have been scaled up:"
  for deploy in "${_deployments[@]}"; do
    echo "- $deploy"
  done

  seconds_at_start=$(date +%s)
  iteration_idx=1
  while true; do
    all_ok=1
    for deploy in "${_deployments[@]}"; do
      unavailable_replicas_kubectl=$(kubectl -n "$_ns" get deploy ${deploy} -o jsonpath='{.status.unavailableReplicas}')
      unavailable_replicas=${unavailable_replicas_kubectl:-0}

      if [[ $unavailable_replicas != 0 ]]; then
        echo " - $deploy: ${unavailable_replicas} pods unavailable ($(date +'%H:%M:%S'))"
        all_ok=0
      fi
    done

    if [[ $all_ok == 1 ]]; then
      break
    fi

    if [[ $(( iteration_idx % 10 )) == 0 ]]; then
      echo "This is poll iteration #${iteration_idx}, showing kubernetes events in the namespace:"
      kubectl -n "$_ns" get event --sort-by=lastTimestamp | sed 's/^/|  |  /g'
    fi

    seconds_elapsed=$(( $(date +%s) - $seconds_at_start ))
    echo "Seconds elapsed: $seconds_elapsed (timeout at $_rollout_timeout)"
    if [[ $seconds_elapsed -gt $_rollout_timeout ]]; then
      echo "Deployment exceeded the timeout. Aborting! The deployment will be left in its current state for manual inspection."
      exit 1
    fi

    iteration_idx=$(( iteration_idx + 1 ))
    sleep 5
  done
  echo "All deployments have been scaled up!"
}

get_pace_ingresses() {
  kubectl -n "$1" get ingresses.v1.networking.k8s.io --no-headers -o custom-columns=":metadata.name" --selector pace.rohea.com/component=pace-ingress
}

get_deployments_to_scale() {
  kubectl -n "$1" get deployment -l rohea.com/stop-during-deploy='true' --no-headers -o custom-columns=":metadata.name"
}

patch_ingresses_to_maintenance_page() {
  _ns="$1"
  ingresses_names=$(get_pace_ingresses "$_ns")
  if [[ -z "$ingresses_names" ]]; then
    echo "No applicable Ingress resources found to patch. Scaling down the deployment but there will not be a nice maintenance frontpage."
  else
    echo "Patching the following Ingress resources to point to the maintenance page:"
    for ing in $ingresses_names; do
      echo "  - '$ing'"
    done
  fi

  for ingress_name in $ingresses_names; do
    echo "Patching ingress: '$ingress_name'"
    orig_service_name=$(kubectl -n "$_ns" get ing "$ingress_name" -o jsonpath='{.spec.rules[0].http.paths[0].backend.service.name}')
    echo "  original svc name: \"$orig_service_name\""
    if [[ $orig_service_name != "maintenance-page" ]]; then
      kubectl -n "$_ns" annotate --overwrite ing "$ingress_name" "rohea.com/original-svc=$orig_service_name"
    fi
    kubectl -n "$_ns" patch ingresses.v1.networking.k8s.io "$ingress_name" --type=json \
            -p='[{"op": "replace", "path": "/spec/rules/0/http/paths/0/backend/service/name", "value":"maintenance-page"}]'
  done

  echo "Ingress resources patched"
}

patch_ingresses_to_regular_services() {
  _ns="$1"

  echo "Patching the following Ingress resources to point their original services:"
  for ing in $ingresses_names; do
    echo "  - '$ing'"
  done

  # Patch ingresses to point to their original services. The original service name is
  # stored in the annotation if the Ingress resource.
  for ingress_name in $ingresses_names; do
    echo "Patching ingress: '$ingress_name'"
    orig_service_name=$(kubectl -n "$_ns" get ing "$ingress_name" -o jsonpath='{.metadata.annotations.rohea\.com/original-svc}')
    if [[ -z "$orig_service_name" ]]; then
      echo "Ingress \"$ingress_name\" does not have the \"rohea.com/original-svc\" annotation. Cannot disable maintenance."
      exit 1
    fi
    echo "  restoring original svc name: \"$orig_service_name\""
    kubectl -n "$_ns" patch ingresses.v1.networking.k8s.io "$ingress_name" --type=json \
            -p='[{"op": "replace", "path": "/spec/rules/0/http/paths/0/backend/service/name", "value":"'"$orig_service_name"'"}]'
  done
}

#
# Enable maintenance mode for a k8s Pace deployment
#
# Args:
#   $1: Kubernetes namespace where to enable the maintenance mode
#
maintenance_enable() {
  _ns="$1"

  if ! kubectl -n "$_ns" get deployment maintenance-page >/dev/null; then
    echo "There is no deployment named 'maintenance-page' in the namespace '$_ns'. Cannot enable maintenance mode!"
    return
  fi

  echo "Deployment 'maintenance-page' found in namespace '$_ns'"

  # Scale up maintenance page, redirect ingresses to it
  kubectl -n "$_ns" scale deployment/maintenance-page --replicas=1
  wait_for_rollout "$_ns" maintenance-page

  patch_ingresses_to_maintenance_page "$_ns"

  deployments_to_scale_down=$(get_deployments_to_scale "$_ns")
  if [[ -n $deployments_to_scale_down ]]; then
    echo "Will scale down the following deployments:"
    for d in $deployments_to_scale_down; do
      echo "  - '${d}'"
    done

    kubectl -n "$_ns" scale deployment -l rohea.com/stop-during-deploy='true' --replicas 0
    wait_for_zero_scale "$_ns"
  else
    echo "No deployments to scale down, continuing"
  fi
}

maintenance_disable() {
  _ns="$1"

  if ! kubectl -n "$_ns" get deployment maintenance-page >/dev/null; then
    echo "There is no deployment named 'maintenance-page' in the namespace '$_ns'. Cannot disable maintenance mode!"
    return 1
  fi

  echo "Deployment 'maintenance-page' found in namespace '$_ns'"

  ingresses_names=$(get_pace_ingresses "$_ns")
  if [[ -z "$ingresses_names" ]]; then
    echo "No ingress resources found. This does not look like a valid deployment. Cannot disable maintenance page."
    exit 1
  fi

  # Restore the original deployments replicas
  echo "Will scale up the following deployments:"
  deployments_to_scale=$(get_deployments_to_scale "$_ns")
  for d in $deployments_to_scale; do
    echo "  - '${d}'"
  done

  for d in $deployments_to_scale; do
    original_replicas=$(kubectl -n "$_ns" get deployment "$d" -o jsonpath='{.metadata.annotations.rohea\.com/target-replicas}')
    scale_to=${original_replicas:-1}
    echo "Scaling deployment $d to $scale_to replicas"
    kubectl -n "$_ns" scale deployment "$d" --replicas $scale_to
  done

  sleep 5

  # Gather deployments that need to be waited for, convert the list to array and pass to the wait function
  _d=$(get_deployments_to_scale "$_ns")
  IFS=$'\n' arr=(${_d})
  wait_for_rollout "$_ns" "${arr[@]}"

  patch_ingresses_to_regular_services "$_ns"

  # scale down maintenance page because it is no longer needed
  kubectl -n "$_ns" scale deployment/maintenance-page --replicas=0
}

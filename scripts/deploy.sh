#!/bin/bash

set -e -E

pace_stack_fn=pace-stack.yaml
migrations_fn=migrations-job.yaml

help() {
  echo "Usage: deploy.sh APP_NAME NAMESPACE

  This script deploys a Pace application into a Kubernetes environment. The deploy is done in several steps:
    - Spin up the maintenance page, route the traffic there
    - Scale down all other components of the Pace stack
    - Run database migrations by deploying a Job
    - Deploy a new version of the Pace stack
    - Spin down the maintenance page, route traffic to Pace

  The script expects two files in the current working directory:
    - ${pace_stack_fn}     - all resources of the Pace stack
    - ${migrations_fn} - the Job that executes migrations
  These files need to be created _before_ running this script, probably through 'helm template'.

  Arguments:
    APP_NAME  is the slug of the app, e.g. 'business-finland'
    NAMESPACE is the Kubernetes namespace where to deploy, e.g. 'test-env'

  Options:
    --skip-migrations   do not run migrations, just deploy"
  exit 0
}

assert_file_exists() {
  if [[ ! -f "$1" ]]; then
    echo "File '$1' not found."
    exit 1
  fi
}

ensure_kubectl_context_correct() {
  if [[ ${REQUIRED_KUBECTL_CONTEXT:-undef} != undef ]]; then
    current_ctx=$(kubectl config current-context)
    if [[ $current_ctx != $REQUIRED_KUBECTL_CONTEXT ]]; then
      echo "This deployment specifies a required kubectl context \"${REQUIRED_KUBECTL_CONTEXT}\" (defined in Helm values under .meta.requireKubectlContext), but current context is \"${current_ctx}\". Aborting the deploy."
      exit 1
    fi
  fi
}

# Interactive confirmation prompt for the user
block_until_user_confirmed() {
  msg="$1"
  _answer="init"
  echo "* * * * * * * * * *"
  while [[ $_answer != "y" ]]; do
    echo "  $msg"
    printf "  Type in 'y' and press Enter when ready to continue: "
    read -r _answer
  done
}

# Import functions
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
source "$DIR/common.sh"

#
# Argument and parameter parsing
#
POSITIONAL=()
SKIP_MIGRATIONS=false

while [[ $# -gt 0 ]]
do
  key="$1"

  case $key in
      --skip-migrations)
      SKIP_MIGRATIONS=true
      shift # past argument
      ;;
      --help)
      help
      ;;
      *)    # unknown option
      POSITIONAL+=("$1") # save it in an array for later
      shift # past argument
      ;;
  esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters

#
# End of parameter handling
#

if [[ $# != 2 ]]; then
  echo "Expected 2 arguments, got $#"
  exit 1
fi

assert_file_exists "$pace_stack_fn"
assert_file_exists "$migrations_fn"

APP_NAME="$1"
NAMESPACE="$2"
DATETIME=$(date +'%Y-%m-%d-%H-%M-%S')
KEEP_LAST_X_MIGRATION_JOBS=3
rollout_wait_timeout="8m"

source .meta_deploy_directives
ensure_kubectl_context_correct

echo "Deploying app '${APP_NAME}' into namespace '${NAMESPACE}'"

# Returns the phase of a given pod
#
#  $1: the Kubernetes namespace where to work
#  $2: the pod name
#
function get_pod_phase() {
  _ns="$1"
  _pod_name="$2"

  kubectl -n "$_ns" get pod "$_pod_name" -o jsonpath="{.status.phase}"
}

#
# The function will wait for a migration job to finish, both for successful and failed state.
#
#  $1: the Kubernetes namespace where to work
#  $2: the name of the migrations Job
#
# From: https://stackoverflow.com/a/66676381/428173
function wait_for_migration_job_finish()
{
  _ns="$1"
  _job_name="$2"

  echo "Waiting for the migration job \"$_job_name\" in namespace \"$_ns\" to finish..."

  _pod_name=$(kubectl -n "$_ns" get pods --no-headers -o custom-columns=":metadata.name" -l "job-name=$_job_name")
  while [[ ! $_pod_name ]]; do
    echo "No pod created for migration job \"$_job_name\" yet, re-checking in 5 seconds..."
    sleep 5
    _pod_name=$(kubectl -n "$_ns" get pods --no-headers -o custom-columns=":metadata.name" -l "job-name=$_job_name")
  done
  echo "The pod associated with the job is: \"$_pod_name\""

  # Wait until the pod is running
  while true; do
    phase=$(get_pod_phase "$_ns" "$_pod_name")
    if [[ $phase == Pending ]]; then
      echo "|-------------------------------------------------------"
      echo "|  Pod is in a 'Pending' phase, printing its events:"
      kubectl -n "$_ns" get event --field-selector involvedObject.name="$_pod_name" --sort-by=lastTimestamp -o custom-columns="LAST SEEN:.lastTimestamp,REASON:.reason,MESSAGE:.message" | sed 's/^/|  |  /g'
      echo "|  NOTE: also check earlier events printed out by the script. The events only stick around for a limited period of time and they stop being printed out after a few minutes."
      echo "|  For troubleshooting of deploy problems, see https://git.rohea.com/ops/documentation/-/blob/master/docs/ci-cd/ci-cd.md ."
      sleep 10
    else
      echo "Pod is in a '$phase' phase, continuing"
      sleep 2  # Just in case the pod still needs a little time to properly come up /shrug
      break
    fi
  done

  # Stream the logs of the pod. Note that this command will exit with 0 exit code even if the pod terminates with failure.
  #   Filter out some lines that we are not interested in seeing in the the CI log output, like audit logs
  kubectl -n "$_ns" logs -f "$_pod_name" | grep -v -E '"channel":"audit"'

  while true; do
    # Check the status of the pod - did it succeed?
    phase=$(get_pod_phase "$_ns" "$_pod_name")
    if [[ $phase == Running ]]; then
      echo "Migration pod is still Running, will re-try in 5 seconds"
      sleep 5
      continue
    fi

    if [[ $phase == Succeeded ]]; then
      echo ""
      echo "Migration job finished successfully."
      break
    fi

    echo ""
    echo "Migration job finished. Pod phase: '$phase'"
    echo "Migration job failed! Aborting the deploy. It is possible that the database is in an inconsistent state so automatic rollback is not possible. Please fix everything manually."
    exit 1
  done
}

function delete_resource_if_exists()
{
  _name="$1"
  echo "Deleting resource \"$_name\" if it exists..."

  if kubectl -n "$NAMESPACE" get "$_name" >/dev/null 2>&1; then
    kubectl -n "$NAMESPACE" delete "$_name"
  fi
}

if ! kubectl describe ns/"$NAMESPACE" >/dev/null 2>&1; then
  echo "Namespace '$NAMESPACE' does not exist yet, creating..."
  kubectl create ns "$NAMESPACE"
fi

maintenance_enable "$NAMESPACE"

#
# Clearing out all failed pods
#
failed_pods=$(kubectl -n "$NAMESPACE" get pods --field-selector status.phase==Failed --ignore-not-found --no-headers)
if [[ -n "$failed_pods" ]]; then
  echo "Failed pods in namespace $NAMESPACE that will be deleted:"
  echo "$failed_pods"
  echo "$failed_pods" | awk '{ print $1 }' | xargs kubectl -n "$NAMESPACE" delete pod
else
  echo "No failed pods in namespace $NAMESPACE, not deleting any pods."
fi

if [[ ${STOP_ON_DEPLOY_FOR_DB_BACKUP:-false} == true ]]; then
  block_until_user_confirmed "Deployment process paused. Now is the time to make a database backup."
fi

#
# Database migrations
#
if [[ "$SKIP_MIGRATIONS" == "true" ]]; then
  echo "Skipping migrations due to --skip-migrations flag enabled"
else
  echo "Deploying the database migration job..."

  kubectl -n "$NAMESPACE" apply -f "${migrations_fn}"
  migration_job_name=$(kubectl -n "$NAMESPACE" get -f "${migrations_fn}" --no-headers -o custom-columns=":metadata.name" -l 'rohea.com/component=pace-database-migrations')
  echo "  ... with name \"$migration_job_name\""
  wait_for_migration_job_finish "$NAMESPACE" "$migration_job_name"

  # Remove old migration jobs
  echo "Pruning previous migration jobs (keeping last $KEEP_LAST_X_MIGRATION_JOBS)..."
  jobs_to_prune=$(kubectl -n "$NAMESPACE" get jobs -l rohea.com/app=pace,rohea.com/component=pace-database-migrations --no-headers -o custom-columns=:metadata.name | sort -r | awk 'NR>'"${KEEP_LAST_X_MIGRATION_JOBS}"' { print $1 }')
  for job in $jobs_to_prune; do
    kubectl -n "$NAMESPACE" delete job "$job"
  done
fi

#
# Deploy new code
#
echo "Deploying new code..."
kubectl -n "$NAMESPACE" apply -f "$pace_stack_fn"

patch_ingresses_to_maintenance_page "$NAMESPACE"

#
# Wait for all the deployment objects to start up
#
_d=$(get_deployments_to_scale "$_ns")
IFS=$'\n' arr=(${_d})
wait_for_rollout "$NAMESPACE" "${arr[@]}"

patch_ingresses_to_regular_services "$NAMESPACE"

#
# Delete old/deprecated resources
#
echo 'Reading deploy tag from file "deploy_tag"'
_deploy_tag=$(cat deploy_tag)
echo "Using deploy tag \"${_deploy_tag}\""

echo "Deleting old resources labelled with 'meta.rohea.com/resource-clearable=true' and meta.rohea.com/deploy-tag NOT equal to \"${_deploy_tag}\""
resources_to_clear=$(kubectl -n "$NAMESPACE" get deploy,job,service,ing,networkpolicy -l 'meta.rohea.com/deploy-tag!='"${_deploy_tag}"',meta.rohea.com/resource-clearable=true' --no-headers -oname)
if [[ ! $resources_to_clear ]]; then
  echo "  No old resources to delete"
else
  for resource in $resources_to_clear; do
    echo "  Deleting ${resource}..."
    kubectl -n "$NAMESPACE" delete "$resource"
  done
fi

if kubectl -n "$NAMESPACE" get deployment maintenance-page; then
  echo "maintenance page deployment exists. Scaling down to 0 replicas."
  kubectl -n "$NAMESPACE" scale deployment/maintenance-page --replicas=0
else
  echo "maintenance page deployment does not exist, skipping its scaling down."
fi

echo "Deployment has finished successfully"

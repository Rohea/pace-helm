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

echo "Deploying app '${APP_NAME}' into namespace '${NAMESPACE}'"

# The function will block until there are zero pods with the following labels:
#   rohea.com/installation: $APP_NAME
function wait_for_zero_scale()
{
  ATTEMPTS=100
  i=0
  while [[ "$i" -lt $ATTEMPTS ]]; do
    printf "\n********************************\nChecking the number of pods labelled with '%s'\n" 'rohea.com/stop-during-deploy="true"'

    pods_output=$(kubectl -n "$NAMESPACE" get pods -l rohea.com/app=pace -l rohea.com/installation="$APP_NAME" -l rohea.com/stop-during-deploy='true')

    printf "\n----\n%s\n----\n" "$pods_output"
    pods_count_incl_header=$(echo "$pods_output" | wc -l)
    echo "Current number of pods waiting to be terminated: $(( pods_count_incl_header - 1))"

    if [[ $pods_count_incl_header -eq 1 ]]; then
      echo "Pods have been scaled down."
      break
    else
      echo "Pods have not yet been scaled down. Re-checking in 5 seconds..."
    fi

    sleep 5
  done
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
  echo "The pod associated with the job is: \"$_pod_name\""

  while true; do
    if kubectl -n "$_ns" wait --for=condition=complete --timeout=0 job "$_job_name" 2>/dev/null; then
      job_result=0
      break
    fi

    if kubectl -n "$_ns" wait --for=condition=failed --timeout=0 job "$_job_name" 2>/dev/null; then
      job_result=1
      break
    fi

    sleep 3
  done

  echo "********************************"
  echo "Migrations job log output (pod $_pod_name)"
  echo "********************************"
  kubectl -n "$_ns" logs --tail=-1 "$_pod_name"
  echo "********************************"

  if [[ $job_result -eq 1 ]]; then
      echo ""
      echo "Migration job failed! Aborting the deploy. It is possible that the database is in an inconsistent state so automatic rollback is not possible. Please fix everything manually."
      exit 1
  fi
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

#
# Check if a deployment already exists. If it does, then switch ingress to maintenance mode and scale down
# the deployment
#
if kubectl -n "$NAMESPACE" get deployment pace; then
  echo "pace deployment already exists. Will scale it down first."

  if kubectl -n "$NAMESPACE" get deployment maintenance-page; then
    echo "maintenance page deployment exists. Scaling up to 1 replica."
    kubectl -n "$NAMESPACE" scale deployment/maintenance-page --replicas=1

    # TODO we sleep here instead of polling status because the GitLab Kubernetes agent connection trips up.. see todo below
    # kubectl -n "$NAMESPACE" rollout status deployment/maintenance-page
    sleep 10
  else
    echo "maintenance page deployment does not exist, skipping its scaling up."
  fi

  #
  # Redirecting ingress traffic to the maintenance-page component
  #
  # Note: this command expects that there is only a single rule with a single HTTP path config in the ingress.
  #
  echo "Enabling maintenance page..."
  ingresses_names=$(kubectl -n "$NAMESPACE" get ingresses.v1.networking.k8s.io --no-headers -o custom-columns=":metadata.name" --selector pace.rohea.com/component=pace-ingress)
  if [[ -z "$ingresses_names" ]]; then
    echo "  No ingresses defined, skipping patching it for maintenance."
    # TODO: instead of skipping the ingress patch there could be a file that deploys the maintenance page and relevant ingress -- we'd get maintenance during initial deploy
  else
    for ingress_name in $ingresses_names; do
      echo "  Patching ingress: $ingress_name"
      kubectl -n "$NAMESPACE" patch ingresses.v1.networking.k8s.io "$ingress_name" --type=json \
              -p='[{"op": "replace", "path": "/spec/rules/0/http/paths/0/backend/service/name", "value":"maintenance-page"}]'
    done
  fi

  #
  # Stopping the previous deployment
  #
  echo "Scaling down the current deployments..."
  kubectl -n "$NAMESPACE" scale deployment pace --replicas 0 || true  # todo this can be removed when all deployments are annotated with rohea.com/stop-during-deploy='true'
  kubectl -n "$NAMESPACE" scale deployment express --replicas 0 || true  # todo this can be removed when all deployments are annotated with rohea.com/stop-during-deploy='true'
  kubectl -n "$NAMESPACE" scale deployment -l rohea.com/stop-during-deploy='true' --replicas 0 || true

  # Clearing out all failed pods
  failed_pods=$(kubectl -n "$NAMESPACE" get pods --field-selector status.phase==Failed --ignore-not-found --no-headers)
  if [[ -n "$failed_pods" ]]; then
    echo "Failed pods in namespace $NAMESPACE that will be deleted:"
    echo "$failed_pods"
    echo "$failed_pods" | awk '{ print $1 }' | xargs kubectl -n "$NAMESPACE" delete pod
  else
    echo "No failed pods in namespace $NAMESPACE, not deleting any pods."
  fi

  wait_for_zero_scale
else
  echo "There is no existing deployment, not setting maintenance page on"
fi

#
# Database migrations
#
if [[ "$SKIP_MIGRATIONS" == "true" ]]; then
  echo "Skipping migrations due to --skip-migrations flag enabled"
else
  echo "Deploying the database migration job..."

  kubectl -n "$NAMESPACE" apply -f "${migrations_fn}"
  migration_job_name=$(kubectl -n "$NAMESPACE" get -f "${migrations_fn}" --no-headers -o custom-columns=":metadata.name")
  echo "  ... with name \"$migration_job_name\""
  wait_for_migration_job_finish "$NAMESPACE" "$migration_job_name"

  # Remove old migration jobs
  echo "Pruning previous migration jobs (keeping last $KEEP_LAST_X_MIGRATION_JOBS)..."
  jobs_to_prune=$(kubectl -n "$NAMESPACE" get jobs -l rohea.com/app=pace -l rohea.com/component=pace-database-migrations --no-headers -o custom-columns=:metadata.name | sort -r | awk 'NR>'"${KEEP_LAST_X_MIGRATION_JOBS}"' { print $1 }')
  for job in $jobs_to_prune; do
    kubectl -n "$NAMESPACE" delete job "$job"
  done
fi

#
# Delete old/deprecated resources
#
echo "Deleting old resources..."
delete_resource_if_exists "ingress/${APP_NAME}"
delete_resource_if_exists "ingress/${APP_NAME}-pacedev"

#
# Deploying new image
#
echo "Deploying new code..."
kubectl -n "$NAMESPACE" apply -f "$pace_stack_fn"

#
# Wait for all the deployment objects to either start up or crash
#
# echo "I will now wait for all the deployments in namespace $NAMESPACE to either succeed or fail."
# echo "I will wait at most '$rollout_wait_timeout'. But it is highly recommended that every deployment has a 'spec.progressDeadlineSeconds' defined with a reasonably small value after which the deployment will be considered failed."
#
# for deploy_name in $(kubectl -n "$NAMESPACE" get deploy --output name); do
#   echo "Waiting for rollout status of ${deploy_name}..."
#   kubectl -n "$NAMESPACE" rollout status "$deploy_name" --timeout "$rollout_wait_timeout"
# done

# TODO this is here instead of the proper waiting through kubectl API due to a GitLab bug: https://gitlab.com/gitlab-org/gitlab/-/issues/343148
#      when upgraded and bug is fixed, remove the sleep and uncomment the waiting above
sleep 60

if kubectl -n "$NAMESPACE" get deployment maintenance-page; then
  echo "maintenance page deployment exists. Scaling down to 0 replicas."
  kubectl -n "$NAMESPACE" scale deployment/maintenance-page --replicas=0
else
  echo "maintenance page deployment does not exist, skipping its scaling down."
fi

echo "Deployment has finished successfully"

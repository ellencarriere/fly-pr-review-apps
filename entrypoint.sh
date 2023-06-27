#!/bin/sh -l

set -ex

if [ -n "$INPUT_PATH" ]; then
  # Allow user to change directories in which to run Fly commands.
  cd "$INPUT_PATH" || exit
fi

PR_NUMBER=$(jq -r .number /github/workflow/event.json)
if [ -z "$PR_NUMBER" ]; then
  echo "This action only supports pull_request actions."
  exit 1
fi

# install the fly CLI tool
flyctl_version="${INPUT_FLYCTL_VERSION:-latest}"
curl -LJO https://fly.io/install.sh \
  && chmod +x install.sh \
  && FLYCTL_INSTALL=/usr/local ./install.sh $flyctl_version
flyctl version

REPO_NAME=$(jq -r .repository.name /github/workflow/event.json)
EVENT_TYPE=$(jq -r .action /github/workflow/event.json)

# Default the Fly app name to {repo_name}-pr-{pr_number}
app="${INPUT_NAME:-$REPO_NAME-pr-$PR_NUMBER}"
# # Default the Fly app name to {repo_name}-pr-{pr_number}-postgres
postgres_app="${INPUT_POSTGRES:-$REPO_NAME-pr-$PR_NUMBER-postgres}"
region="${INPUT_REGION:-${FLY_REGION:-ord}}"
org="${INPUT_ORG:-${FLY_ORG:-personal}}"
image="$INPUT_IMAGE"
dockerfile="$INPUT_DOCKERFILE"
memory="$INPUT_MEMORY"

# only wait for the deploy to complete if the user has requested the wait option
# otherwise detach so the GitHub action doesn't run as long
if [ "$INPUT_WAIT" = "true" ]; then
  detach=""
else
  detach="--detach"
fi

if ! echo "$app" | grep "$PR_NUMBER"; then
  echo "For safety, this action requires the app's name to contain the PR number."
  exit 1
fi

# If PR is closed or merged, the app and its associated DB will be deleted
if [ "$EVENT_TYPE" = "closed" ]; then
  flyctl apps destroy "$app" -y || true
  if [ -n "$INPUT_POSTGRES" ]; then
    flyctl apps destroy "$postgres_app" -y || true
  fi

  message="Review app deleted."
  echo "::set-output name=message::$message"
  exit 0
fi

# Create postgres app if it does not already exist
if [ -n "$INPUT_POSTGRES" ]; then
  if ! flyctl status --app "$postgres_app"; then
    flyctl postgres create --name "$postgres_app" --region "$region" --org "$org" --vm-size shared-cpu-1x --volume-size 1 --initial-cluster-size 1 || true
  fi
fi

# Deploy the Fly app, creating it first if needed.
if ! flyctl status --app "$app"; then
  flyctl launch --no-deploy --copy-config --name "$app" --image "$image" --dockerfile "$dockerfile" --region "$region" --org "$org"
  if [ -n "$INPUT_SECRETS" ]; then
    echo $INPUT_SECRETS | tr " " "\n" | flyctl secrets import --app "$app"
  fi
  flyctl postgres attach "$postgres_app" --app "$app"
  flyctl deploy $detach --app "$app" --region "$region" --image "$image" --strategy immediate --wait-timeout 240 --vm-cpus 2

  statusmessage="Review app created. It may take a few minutes for the app to deploy."
elif [ "$EVENT_TYPE" = "synchronize" ]; then
  flyctl deploy $detach --app "$app" --region "$region" --image "$image" --strategy immediate --wait-timeout 240 --vm-cpus 2
  statusmessage="Review app updated. It may take a few minutes for your changes to be deployed."
fi


# Make some info available to the GitHub workflow.
fly status --app "$app" --json >status.json
hostname=$(jq -r .Hostname status.json)
appid=$(jq -r .ID status.json)

echo "::set-output name=hostname::$hostname"
echo "::set-output name=url::https://$hostname"
echo "::set-output name=id::$appid"
echo "::set-output name=message::$statusmessage https://$hostname"

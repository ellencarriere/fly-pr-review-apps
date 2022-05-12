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

REPO_OWNER=$(jq -r .event.base.repo.owner /github/workflow/event.json)
REPO_NAME=$(jq -r .event.base.repo.name /github/workflow/event.json)
EVENT_TYPE=$(jq -r .action /github/workflow/event.json)

# Default the Fly app name to pr-{number}-{repo_owner}-{repo_name}
app="${INPUT_NAME:-pr-$PR_NUMBER-$REPO_OWNER-$REPO_NAME}"
postgres_app="${INPUT_POSTGRES_NAME:-pr-$PR_NUMBER-$REPO_OWNER-$REPO_NAME-postgres}"
region="${INPUT_REGION:-${FLY_REGION:-iad}}"
org="${INPUT_ORG:-${FLY_ORG:-personal}}"
image="$INPUT_IMAGE"

if ! echo "$app" | grep "$PR_NUMBER"; then
  echo "For safety, this action requires the app's name to contain the PR number."
  exit 1
fi

# PR was closed - remove the Fly app if one exists and exit.
if [ "$EVENT_TYPE" = "closed" ]; then
  flyctl apps destroy "$app" -y || true
  if [ -n "$INPUT_POSTGRES" ]; then
    flyctl apps destroy "$postgres_app" -y || true
  fi
  exit 0
fi

# Create postgres app if it does not already exist
if [ -n "$INPUT_POSTGRES" ]; then
  if ! flyctl status --app "$postgres_app"; then
    flyctl postgres create --name "$postgres_app" --region "$region" --organization "$org" --vm-size shared-cpu-1x --volume-size 1 --initial-cluster-size 1 || true
  fi
fi

# Deploy the Fly app, creating it first if needed.
if ! flyctl status --app "$app"; then
  flyctl launch --no-deploy --copy-config --name "$app" --image "$image" --region "$region" --org "$org"
  if [ -n "$INPUT_SECRETS" ]; then
    echo $INPUT_SECRETS | tr " " "\n" | flyctl secrets import --app "$app"
  fi
  flyctl postgres attach --app "$app" --postgres-app "$INPUT_POSTGRES" || true
  flyctl deploy --app "$app" --region "$region" --image "$image" --region "$region" --strategy immediate
elif [ "$INPUT_UPDATE" != "false" ]; then
  flyctl deploy --app "$app" --region "$region" --image "$image" --region "$region" --strategy immediate
fi


# Make some info available to the GitHub workflow.
fly status --app "$app" --json >status.json
hostname=$(jq -r .Hostname status.json)
appid=$(jq -r .ID status.json)
echo "::set-output name=hostname::$hostname"
echo "::set-output name=url::https://$hostname"
echo "::set-output name=id::$appid"

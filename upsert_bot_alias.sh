#!/bin/bash

# Usage: ./upsert_bot_alias.sh <BOT_ID> <LOCALE_ID> <BOT_VERSION> <LAMBDA_ARN> <LOGS_ARN>

set -e

ALIAS_NAME="PublicAlias"

# Check if the alias already exists
CURRENT_ALIAS_ID=$(aws lexv2-models list-bot-aliases --bot-id $1 --query "botAliasSummaries[?botAliasName == '$ALIAS_NAME'].botAliasId | [0]" --output text)

if [[ $CURRENT_ALIAS_ID == "None" ]]; then
  echo "Creating a new alias"
  CURRENT_ALIAS_ID=$(aws lexv2-models create-bot-alias --bot-id $1 --bot-alias-name $ALIAS_NAME --query botAliasId --output text)
fi

echo "Updating the alias"
# Enable lambda execution and chat logs
aws lexv2-models update-bot-alias --bot-id $1 --bot-alias-id $CURRENT_ALIAS_ID --bot-alias-name $ALIAS_NAME --bot-version $3 --bot-alias-locale-settings '{"'$2'":{"enabled":true,"codeHookSpecification":{"lambdaCodeHook":{"lambdaARN":"'$4'","codeHookInterfaceVersion":"1.0"}}}}'

# --conversation-log-settings '{"textLogSettings":[{"enabled":true,"destination":{"cloudWatch":{"cloudWatchLogGroupArn":"'$5'","logPrefix":""}}}]}'
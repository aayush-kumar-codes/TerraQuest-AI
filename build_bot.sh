#!/bin/bash

# Usage: ./build_bot.sh <BOT_ID> <LOCALE_ID>

set -e

echo "Building bot with ID $1"
aws lexv2-models build-bot-locale --bot-id $1 --locale-id $2 --bot-version DRAFT

# Wait for the build to finish
while [ "$(aws lexv2-models describe-bot-locale --bot-id $1 --locale-id $2 --bot-version DRAFT --query botLocaleStatus --output text)" != "Built" ]
do
  sleep 5
done
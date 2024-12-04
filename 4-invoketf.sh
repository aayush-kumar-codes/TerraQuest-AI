#!/bin/bash

while true; do
  aws lambda invoke --function-name demo-lambda --payload fileb://event.json out.json
  cat out.json
  echo ""
  sleep 2
  break
done
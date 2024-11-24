#!/bin/bash

# FUNCTION=$(aws cloudformation describe-stack-resource --stack-name test-stack-saurabh-2 --logical-resource-id BedRockLexLambda --query 'StackResourceDetail.PhysicalResourceId' --output text)

# echo $FUNCTION


while true; do
  echo '{}' > out.json
  aws lambda invoke --function-name BedRockLexLambda --payload fileb://lex.json out.json
  cat out.json | jq '.'
  echo ""
  sleep 2
  break
done
#!/bin/bash

FUNCTION=$(aws cloudformation describe-stack-resource --stack-name test-stack-saurabh --logical-resource-id MyLambdaFunction2 --query 'StackResourceDetail.PhysicalResourceId' --output text)

echo $FUNCTION


while true; do
  aws lambda invoke --function-name $FUNCTION --payload fileb://event.json out.json
  cat out.json
  echo ""
  sleep 2
  break
done
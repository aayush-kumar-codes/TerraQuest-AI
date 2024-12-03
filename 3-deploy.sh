#!/bin/bash

STACK_NAME=test-stack-saurabh

rm out.yml
aws cloudformation package --template-file template.yaml --s3-bucket $STACK_NAME --output-template-file out.yml
aws cloudformation deploy --template-file out.yml --stack-name $STACK_NAME --capabilities CAPABILITY_NAMED_IAM
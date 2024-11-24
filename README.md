### Terraform AWS Bedrock, LEX, Kendra, Lamba RAG Agent


Fully setup for RAG agent using terraform




export AWS_DEFAULT_PROFILE=sydney

Terrafrom code to connect aws security hub with aws event bridget and trigger lambda.


Lambda uses aws bedrock to generate a report.


To Run

sh 2-build-layer.sh

terraform init 

terraform apply

sh 4-invoketf.sh


to increase no of issues it picks from security hub can change variable     max_finding = 2  in function/lambda_function.py


aws lexv2-models update-intent --bot-id DKBO1HUUQX --bot-version DRAFT --locale-id en_US --intent-name FallbackIntent --intent-id FALLBCKINT --fulfillment-code-hook '{"enabled": true}'

aws lexv2-models delete-intent \
  --bot-id DKBO1HUUQX \
  --bot-version DRAFT \
  --locale-id en_US \
  --intent-id FALLBCKINT


  aws lexv2-models list-bot-aliases --bot-id DKBO1HUUQX --query "botAliasSummaries[?botAliasName == 'abc'].botAliasId | [0]" --output text

  aws lexv2-models create-bot-alias --bot-id DKBO1HUUQX --bot-alias-name abc --bot-version 1 --description "Your bot alias description" --output text
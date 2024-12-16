terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.61.0"
    }
  }
}

provider "aws" {
  region = "us-west-2" # Replace with your desired region
}

variable "bucket_name" {
  type        = string
  description = "Name of the S3 bucket to create"
  default     = "my-llm-pdf-bucket-12344"
}

variable "project_name" {
  description = "The name of the project"
  type        = string
  default     = "compliance-check"
}

variable "environment" {
  description = "The deployment environment"
  type        = string
  default     = "prod"
}


data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/function"
  output_path = "${path.module}/function/lambda_function.zip"
}

# Archive file for Lambda Layer
data "archive_file" "layer_zip" {
  type        = "zip"
  source_dir  = "${path.module}/layer/"
  output_path = "${path.module}/layer/layer.zip"
}

# Lambda Layer
resource "aws_lambda_layer_version" "libs" {
  filename            = "layer/layer.zip" # Ensure you zip your layer content
  layer_name          = "blank-python-lib"
  compatible_runtimes = ["python3.8"]
  description         = "Dependencies for the blank-python sample app1"
}


resource "aws_lambda_function" "bedrock_lex_lambda" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "BedRockLexLambda"
  role             = aws_iam_role.bedrock_lambda_execution_role.arn
  handler          = "lambda_lex_function.lambda_handler"
  runtime          = "python3.8"
  timeout          = 500
  memory_size      = 256
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      KENDRA_INDEX_ID   = aws_kendra_index.kendra_index.id
      KENDRA_INDEX_NAME = "${aws_kendra_index.kendra_index.name}-index"
    }
  }

  layers = [aws_lambda_layer_version.libs.arn]
}

resource "aws_lambda_function" "bedrock_aws_config_lambda" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "BedRockAwsConfigLambda"
  role             = aws_iam_role.bedrock_lambda_execution_role.arn
  handler          = "lambda_aws_config_function.lambda_handler"
  runtime          = "python3.8"
  timeout          = 500
  memory_size      = 256
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      KENDRA_INDEX_ID   = aws_kendra_index.kendra_index.id
      KENDRA_INDEX_NAME = "${aws_kendra_index.kendra_index.name}-index"
      EMAIL_FROM        = "saurabh@gmail.com"
      EMAIL_TO          = "saurabh.excel2011@gmail.com"
      EMAIL_SUBJECT     = "AWS Config Compliance Change Notification"
    }
  }

  layers = [aws_lambda_layer_version.libs.arn]
}

resource "aws_iam_role" "bedrock_lambda_execution_role" {
  name = "BedRockLambdaExecutionRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_ses_policy" {
  name = "lambda_ses_policy"
  role = aws_iam_role.bedrock_lambda_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ses:SendEmail",
          "ses:SendRawEmail"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  role       = aws_iam_role.bedrock_lambda_execution_role.name
}

resource "aws_iam_role_policy" "bedrock_access" {
  name = "BedrockAccess"
  role = aws_iam_role.bedrock_lambda_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "bedrock:*"
        Resource = "*"
      }
    ]
  })
}




# EventBridge rule
resource "aws_cloudwatch_event_rule" "compliance_check_rule" {
  name        = "${var.project_name}-${var.environment}-rule"
  description = "Rule to trigger the Lambda function for compliance checks"

  event_pattern = jsonencode({
    source      = ["aws.config"]
    detail-type = ["Config Rules Compliance Change"]
    detail = {
      complianceType = ["COMPLIANT", "NON_COMPLIANT", "NOT_APPLICABLE", "INSUFFICIENT_DATA"]
    }
  })

  tags = {
    Name        = "${var.project_name}-${var.environment}-rule"
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "Terraform"
  }
}

# EventBridge target (Lambda function)
resource "aws_cloudwatch_event_target" "lambda_target" {
  rule      = aws_cloudwatch_event_rule.compliance_check_rule.name
  target_id = "${var.project_name}-${var.environment}-lambda-target"
  arn       = aws_lambda_function.bedrock_aws_config_lambda.arn

  input_transformer {
    input_paths = {
      detail     = "$.detail"
      detailType = "$.detail-type"
      source     = "$.source"
      time       = "$.time"
      id         = "$.id"
      region     = "$.region"
      resources  = "$.resources"
      accountId  = "$.account"
    }
    input_template = <<EOF
{
  "action": "CheckCompliance",
  "event": {
    "id": <id>,
    "detail-type": <detailType>,
    "source": <source>,
    "account": <accountId>,
    "time": <time>,
    "region": <region>,
    "resources": <resources>,
    "detail": <detail>
  }
}
EOF
  }
}

# IAM role for the Bedrock agent
resource "aws_iam_role" "bedrock_agent_role" {
  name = "bedrock_agent_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "bedrock.amazonaws.com"
        }
      }
    ]
  })
}


# AWS Bedrock agent
resource "aws_bedrockagent_agent" "config_non_compliant_agent" {
  agent_name  = "ConfigNonCompliantAgent"
  description = "Agent to handle AWS Config non-compliant events"
  # role_arn    = aws_iam_role.bedrock_agent_role.arn

  agent_resource_role_arn = aws_iam_role.bedrock_agent_role.arn
  instruction             = "Monitor AWS Config events for non-compliant resources and integrate with the existing Lambda function."
  foundation_model        = "anthropic.claude-v2"
}

# AWS Bedrock agent action group
resource "aws_bedrockagent_agent_action_group" "config_action_group" {
  agent_id          = aws_bedrockagent_agent.config_non_compliant_agent.id
  agent_version     = "DRAFT"
  action_group_name = "ConfigComplianceActions"
  description       = "Actions for handling AWS Config compliance events"

  action_group_executor {
    lambda = aws_lambda_function.bedrock_aws_config_lambda.arn
  }

  function_schema {
    member_functions {
      functions {
        name        = "HandleNonCompliantResource"
        description = "Process non-compliant resource and take appropriate action"
        parameters {
          map_block_key = "resourceId"
          type          = "string"
          description   = "The ID of the non-compliant resource"
          required      = true
        }
        parameters {
          map_block_key = "complianceType"
          type          = "string"
          description   = "The type of non-compliance"
          required      = true
        }
        parameters {
          map_block_key = "configRuleName"
          type          = "string"
          description   = "The name of the Config rule that was violated"
          required      = true
        }
      }
    }
  }

}


# Lambda permission to allow EventBridge to invoke the function
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.bedrock_aws_config_lambda.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.compliance_check_rule.arn
}




resource "aws_iam_role_policy" "kendra_access" {
  name = "KendraAccess"
  role = aws_iam_role.bedrock_lambda_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "kendra:*"
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "s3_access" {
  name = "S3Access"
  role = aws_iam_role.bedrock_lambda_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::*",
          "arn:aws:s3:::*/*"
        ]
      }
    ]
  })
}

resource "aws_s3_bucket" "s3_bucket" {
  bucket = var.bucket_name
}


# Create the AWS Bedrock Guardrail resource
resource "awscc_bedrock_guardrail" "pii_masking_guardrail" {
  name                      = "PII-Masking-Guardrail"
  blocked_input_messaging   = "Blocked input"
  blocked_outputs_messaging = "Blocked output"
  description               = "Guardrail to mask sensitive and PII information in AWS Bedrock"

  sensitive_information_policy_config = {

    #     ["ADDRESS" "AGE" "AWS_ACCESS_KEY" "AWS_SECRET_KEY"
    # │ "CA_HEALTH_NUMBER" "CA_SOCIAL_INSURANCE_NUMBER" "CREDIT_DEBIT_CARD_CVV" "CREDIT_DEBIT_CARD_EXPIRY" "CREDIT_DEBIT_CARD_NUMBER" "DRIVER_ID" "EMAIL"
    # │ "INTERNATIONAL_BANK_ACCOUNT_NUMBER" "IP_ADDRESS" "LICENSE_PLATE" "MAC_ADDRESS" "NAME" "PASSWORD" "PHONE" "PIN" "SWIFT_CODE"
    # │ "UK_NATIONAL_HEALTH_SERVICE_NUMBER" "UK_NATIONAL_INSURANCE_NUMBER" "UK_UNIQUE_TAXPAYER_REFERENCE_NUMBER" "URL" "USERNAME" "US_BANK_ACCOUNT_NUMBER"
    # │ "US_BANK_ROUTING_NUMBER" "US_INDIVIDUAL_TAX_IDENTIFICATION_NUMBER" "US_PASSPORT_NUMBER" "US_SOCIAL_SECURITY_NUMBER" "VEHICLE_IDENTIFICATION_NUMBER"],

    pii_entities_config = [
      { action = "ANONYMIZE", type = "NAME" },
      { action = "BLOCK", type = "DRIVER_ID" },
      { action = "ANONYMIZE", type = "USERNAME" },
      # { action = "ANONYMIZE", type = "EMAIL" },
      { action = "ANONYMIZE", type = "PHONE" },
      { action = "BLOCK", type = "US_SOCIAL_SECURITY_NUMBER" },
      { action = "ANONYMIZE", type = "CREDIT_DEBIT_CARD_NUMBER" },
      { action = "ANONYMIZE", type = "ADDRESS" },
      { action = "ANONYMIZE", type = "IP_ADDRESS" },
      { action = "ANONYMIZE", type = "AGE" },
      { action = "BLOCK", type = "AWS_ACCESS_KEY" },
      { action = "BLOCK", type = "AWS_SECRET_KEY" },
    ]
    regexes_config = [
      {
        action      = "BLOCK"
        description = "Block SSN-like patterns"
        name        = "ssn_pattern"
        pattern     = "^\\d{3}-\\d{2}-\\d{4}$"
      },
      {
        action      = "ANONYMIZE"
        description = "Mask custom employee ID format"
        name        = "employee_id_pattern"
        pattern     = "EMP-\\d{6}"
      }
    ]

  }
}




resource "aws_iam_role" "kendra_index_role" {
  name = "KendraIndexRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "kendra.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "kendra_cloudwatch_logs" {
  policy_arn = "arn:aws:iam::aws:policy/AWSOpsWorksCloudWatchLogs"
  role       = aws_iam_role.kendra_index_role.name
}

resource "aws_iam_role_policy" "kendra_index_policy" {
  name = "KendraIndexPolicy"
  role = aws_iam_role.kendra_index_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.s3_bucket.arn,
          "${aws_s3_bucket.s3_bucket.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_kendra_index" "kendra_index" {
  name     = "YourStackName-index2"
  role_arn = aws_iam_role.kendra_index_role.arn
  edition  = "DEVELOPER_EDITION"
}

resource "aws_kendra_data_source" "kendra_data_source" {
  index_id = aws_kendra_index.kendra_index.id
  name     = "YourStackName-s3-datasource2"
  type     = "S3"
  role_arn = aws_iam_role.kendra_data_source_role.arn

  configuration {
    s3_configuration {
      bucket_name = aws_s3_bucket.s3_bucket.id
    }
  }
  tags = {
    Name = "YourStackName-s3-datasource2"
  }
}

resource "aws_iam_role" "kendra_data_source_role" {
  name = "KendraDataSourceRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "kendra.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "kendra_data_source_policy" {
  name = "KendraDataSourcePolicy"
  role = aws_iam_role.kendra_data_source_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.s3_bucket.arn,
          "${aws_s3_bucket.s3_bucket.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kendra:BatchPutDocument",
          "kendra:BatchDeleteDocument"
        ]
        Resource = aws_kendra_index.kendra_index.arn
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "lex_log_group" {
  name              = "/aws/lex/YourStackName2"
  retention_in_days = 14
}

resource "aws_iam_role" "bot_runtime_role" {
  name = "LexBotRuntimeRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lexv2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "lex_runtime_role_policy" {
  name = "LexRuntimeRolePolicy"
  role = aws_iam_role.bot_runtime_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "polly:SynthesizeSpeech",
          "comprehend:DetectSentiment",
          "lambda:InvokeFunction",
          "s3:PutObject",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.s3_bucket.arn}/lex-audio-logs/*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = aws_cloudwatch_log_group.lex_log_group.arn
      }
    ]
  })
}

resource "aws_lambda_permission" "allow_lex" {
  statement_id  = "AllowExecutionFromLex"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.bedrock_lex_lambda.function_name
  principal     = "lexv2.amazonaws.com"
}

resource "aws_lexv2models_bot" "chatbot" {
  name     = "LLMChatbot"
  role_arn = aws_iam_role.bot_runtime_role.arn

  data_privacy {
    child_directed = false
  }

  idle_session_ttl_in_seconds = 300

  # type = "BOT"
}

# Add a null_resource to wait for the bot to be ready and not in versioning state
resource "null_resource" "wait_for_bot" {
  depends_on = [aws_lexv2models_bot.chatbot]

  provisioner "local-exec" {
    command = <<EOF
      echo "Starting bot status check..."

      check_bot_status() {
        aws lexv2-models describe-bot --bot-id ${aws_lexv2models_bot.chatbot.id} --region us-west-2 --query 'botStatus' --output text
      }

      bot_status=$(check_bot_status)
      echo "Initial bot status: $bot_status"

      while [ "$bot_status" != "Available" ]; do
        echo "Waiting for bot to be Available... Current status: $bot_status"
        sleep 10
        bot_status=$(check_bot_status)
      done

      echo "Bot is Available. Checking for Versioning state..."

      while [ "$bot_status" = "Versioning" ]; do
        echo "Bot is in Versioning state. Waiting..."
        sleep 10
        bot_status=$(check_bot_status)
      done

      echo "Final bot status: $bot_status"
      echo "Bot check complete. Proceeding with next steps."
    EOF
  }
}


resource "aws_lexv2models_bot_locale" "chatbot_locale" {
  bot_id                           = aws_lexv2models_bot.chatbot.id
  bot_version                      = "DRAFT"
  locale_id                        = "en_US"
  description                      = "LLM Bedrock Bot"
  n_lu_intent_confidence_threshold = 0.70

  voice_settings {
    voice_id = "Ivy"
  }
  # Update default fallback to enable lambda hook
  provisioner "local-exec" {
    command = "aws lexv2-models update-intent --bot-id ${aws_lexv2models_bot.chatbot.id} --locale-id ${aws_lexv2models_bot_locale.chatbot_locale.locale_id} --bot-version DRAFT --intent-id FALLBCKINT --intent-name FallbackIntent --parent-intent-signature=AMAZON.FallbackIntent --dialog-code-hook enabled=true --region us-west-2"
  }
}


resource "aws_lexv2models_bot_version" "chatbot_version" {
  bot_id = aws_lexv2models_bot.chatbot.id
  locale_specification = {
    "en_US" = {
      source_bot_version = "DRAFT"
    }
  }
}


resource "aws_lexv2models_intent" "chatbot" {
  bot_id      = aws_lexv2models_bot.chatbot.id
  bot_version = aws_lexv2models_bot_locale.chatbot_locale.bot_version
  locale_id   = aws_lexv2models_bot_locale.chatbot_locale.locale_id
  name        = "HelloIntent"

  dialog_code_hook {
    enabled = true
  }

  sample_utterance {
    utterance = "Hello"
  }
}

# This builds the bot after creating an intent
resource "null_resource" "my_bot_build" {
  depends_on = [aws_lexv2models_intent.chatbot]

  triggers = {
    bot_id    = aws_lexv2models_bot.chatbot.id
    locale_id = aws_lexv2models_bot_locale.chatbot_locale.locale_id
    # intent = aws_lexv2models_intent.chatbot.sample_utterance
  }

  provisioner "local-exec" {
    command = "./build_bot.sh ${aws_lexv2models_bot.chatbot.id} ${aws_lexv2models_bot_locale.chatbot_locale.locale_id}"
  }
}

# Create a version after building
resource "aws_lexv2models_bot_version" "chatbot" {
  depends_on = [null_resource.my_bot_build]

  bot_id = aws_lexv2models_bot.chatbot.id
  locale_specification = {
    (aws_lexv2models_bot_locale.chatbot_locale.locale_id) = {
      source_bot_version = aws_lexv2models_bot_locale.chatbot_locale.bot_version
    }
  }
}

# Create or update an alias after creating a new version
resource "null_resource" "my_bot_alias" {
  depends_on = [aws_lexv2models_bot_version.chatbot]

  triggers = {
    bot_id         = aws_lexv2models_bot.chatbot.id
    locale_id      = aws_lexv2models_bot_locale.chatbot_locale.locale_id
    latest_version = aws_lexv2models_bot_version.chatbot.bot_version
    lambda_arn     = aws_lambda_function.bedrock_lex_lambda.arn
    logs_arn       = ""
  }

  provisioner "local-exec" {
    command = "./upsert_bot_alias.sh ${aws_lexv2models_bot.chatbot.id} ${aws_lexv2models_bot_locale.chatbot_locale.locale_id} ${aws_lexv2models_bot_version.chatbot.bot_version} '${aws_lambda_function.bedrock_lex_lambda.arn}' ''"
  }
}

# resource "null_resource" "update_fallback_intent" {
#   depends_on = [aws_lexv2models_bot.chatbot]

#   triggers = {
#     always_run = "${timestamp()}"
#   }

#   provisioner "local-exec" {
#     command = <<EOF
#       echo "Starting bot status check..."

#       check_bot_status() {
#         aws lexv2-models describe-bot --bot-id ${aws_lexv2models_bot.chatbot.id} --region us-west-2 --query 'botStatus' --output text
#       }

#       bot_status=$(check_bot_status)
#       echo "Initial bot status: $bot_status"

#       while [ "$bot_status" != "Available" ]; do
#         echo "Waiting for bot to be Available... Current status: $bot_status"
#         sleep 10
#         bot_status=$(check_bot_status)
#       done

#       echo "Bot is Available. Checking for Versioning state..."

#       while [ "$bot_status" = "Versioning" ]; do
#         echo "Bot is in Versioning state. Waiting..."
#         sleep 10
#         bot_status=$(check_bot_status)
#       done

#       echo "Final bot status: $bot_status"
#       echo "Bot check complete. Proceeding with next steps."


#     ALIAS_NAME="PublicAlias"

#     # Check if the alias already exists
#     CURRENT_ALIAS_ID=$(aws lexv2-models list-bot-aliases --bot-id ${aws_lexv2models_bot.chatbot.id} --query "botAliasSummaries[?botAliasName == '$ALIAS_NAME'].botAliasId | [0]" --output text)

#     echo "Final alias id: $CURRENT_ALIAS_ID"

#     if [[ $CURRENT_ALIAS_ID == "None" ]]; then
#       echo "Creating a new alias"
#       CURRENT_ALIAS_ID=$(aws lexv2-models create-bot-alias --bot-id ${aws_lexv2models_bot.chatbot.id} --bot-alias-name $ALIAS_NAME --bot-version 1 --output text)
#       echo "Final bot status: $CURRENT_ALIAS_ID"
#     fi

#     echo "Updating the alias"
#     # Enable lambda execution and chat logs
#     aws lexv2-models update-bot-alias --bot-id ${aws_lexv2models_bot.chatbot.id} --bot-alias-id $CURRENT_ALIAS_ID --bot-alias-name $ALIAS_NAME --bot-version 1 --bot-alias-locale-settings '{"'$2'":{"enabled":true,"codeHookSpecification":{"lambdaCodeHook":{"lambdaARN":"'${bedrock_lex_lambda.lambda.arn}'","codeHookInterfaceVersion":"1.0"}}}}' --conversation-log-settings '{"textLogSettings":[{"enabled":true,"destination":{"cloudWatch":{"cloudWatchLogGroupArn":"'$5'","logPrefix":""}}}]}'

#       echo "Fetching FallbackIntentId... ${aws_lexv2models_bot.chatbot.id}"

#       FallbackIntentId=$(aws lexv2-models list-intents --bot-id ${aws_lexv2models_bot.chatbot.id} --bot-version DRAFT --locale-id en_US --query "intentSummaries[?intentName=='CustomFallbackIntent'].intentId" --output text)

#       echo "Raw FallbackIntentId output: $FallbackIntentId"

#       if [ -z "$FallbackIntentId" ]; then
#         echo "FallbackIntentId is null. Exiting."
#         exit 1
#       else
#         echo "Fetched FallbackIntentId: $FallbackIntentId"
#       fi

#       echo "Updating FallbackIntent with ID: $FallbackIntentId..."

#       aws lexv2-models update-intent \
#         --bot-id ${aws_lexv2models_bot.chatbot.id} \
#         --bot-version DRAFT \
#         --locale-id en_US \
#         --intent-id $FallbackIntentId \
#         --intent-name FallbackIntent \
#         --fulfillment-code-hook '{"enabled": true}'

#       echo "Update completed."
#     EOF
#   }
# }

# resource "awscc_bedrock_guardrail" "example" {
#   name                      = "example_guardrail"
#   blocked_input_messaging   = "Sorry cannot answer this question"
#   blocked_outputs_messaging = "Blocked output"
#   description               = "Example guardrail"

#   content_policy_config = {
#     filters_config = [
#       {
#         input_strength  = "MEDIUM"
#         output_strength = "MEDIUM"
#         type            = "HATE"
#       },
#       {
#         input_strength  = "HIGH"
#         output_strength = "HIGH"
#         type            = "VIOLENCE"
#       }
#     ]
#   }

# }


output "s3_bucket_name" {
  description = "Name of the created S3 bucket"
  value       = aws_s3_bucket.s3_bucket.id
}

output "kendra_index_id" {
  description = "ID of the created Kendra Index"
  value       = aws_kendra_index.kendra_index.id
}

output "kendra_data_source_id" {
  description = "ID of the created Kendra Data Source"
  value       = aws_kendra_data_source.kendra_data_source.id
}
output "lex_bot_id" {
  description = "The ID of the Lex bot"
  value       = aws_lexv2models_bot.chatbot.id
}

# Outputs
output "event_rule_arn" {
  description = "ARN of the EventBridge rule"
  value       = aws_cloudwatch_event_rule.compliance_check_rule.arn
}

output "lambda_function_arn" {
  description = "ARN of the target Lambda function"
  value       = aws_lambda_function.bedrock_aws_config_lambda.arn
}

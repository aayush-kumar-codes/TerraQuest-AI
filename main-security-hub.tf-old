# Configure the AWS provider
provider "aws" {
  region = "us-west-2" # Replace with your desired region
}

# EventBridge rule for Security Hub findings
resource "aws_cloudwatch_event_rule" "security_hub_event_rule" {
  description = "EventBridge rule for Security Hub findings"
  event_pattern = jsonencode({
    source      = ["aws.securityhub"]
    detail-type = ["Security Hub Findings - Imported"]
  })
  state = "ENABLED"
}

# Lambda permission for EventBridge
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.function.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.security_hub_event_rule.arn
}

# Archive file for Lambda function
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/function"
  output_path = "${path.module}/function/lambda_function.zip"
}

# Lambda function
resource "aws_lambda_function" "function" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "demo-lambda"
  role             = aws_iam_role.lambda_execution_role.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.8"
  timeout          = 900
  memory_size      = 256
  description      = "Demo lambda"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  tracing_config {
    mode = "Active"
  }

  layers = [aws_lambda_layer_version.libs.arn]
}

# Archive file for Lambda Layer
data "archive_file" "layer_zip" {
  type        = "zip"
  source_dir  = "${path.module}/layer/python/"
  output_path = "${path.module}/layer/layer.zip"
}

# Lambda Layer
resource "aws_lambda_layer_version" "libs" {
  filename            = "layer/layer.zip"  # Ensure you zip your layer content
  layer_name          = "blank-python-lib"
  compatible_runtimes = ["python3.8"]
  description         = "Dependencies for the blank-python sample app."
}

# IAM role for Lambda
resource "aws_iam_role" "lambda_execution_role" {
  name = "lambda_execution_role"
  
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

# Attach AWSLambdaBasicExecutionRole managed policy
resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Bedrock Access Policy
resource "aws_iam_role_policy" "bedrock_access_policy" {
  name = "BedrockAccess"
  role = aws_iam_role.lambda_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["bedrock:*"]
        Resource = "*"
      }
    ]
  })
}

# Kendra Access Policy
resource "aws_iam_role_policy" "kendra_access_policy" {
  name = "KendraAccess"
  role = aws_iam_role.lambda_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["kendra:*"]
        Resource = "*"
      }
    ]
  })
}

# S3 Access Policy
resource "aws_iam_role_policy" "s3_access_policy" {
  name = "S3Access"
  role = aws_iam_role.lambda_execution_role.id

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

# SecurityHub Access Policy
resource "aws_iam_role_policy" "securityhub_access_policy" {
  name = "SecurityHubAccess"
  role = aws_iam_role.lambda_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "securityhub:GetFindings",
          "securityhub:BatchGetFindings",
          "securityhub:DescribeHub"
        ]
        Resource = "*"
      }
    ]
  })
}

# Add this after the existing provider block

# S3 bucket for Kendra datasource
resource "aws_s3_bucket" "kendra_datasource" {
  bucket = "security-demo-bucket-saurabh"
}

# Upload the PDF file to S3
resource "aws_s3_object" "security_controls_pdf" {
  bucket = aws_s3_bucket.kendra_datasource.id
  key    = "aws-security-controls.pdf"
  # source = "https://docs.aws.amazon.com/pdfs/prescriptive-guidance/latest/aws-security-controls/aws-security-controls.pdf"
  source = "${path.module}/aws-security-controls.pdf"
}

# Kendra Index
resource "aws_kendra_index" "example" {
  name        = "example-index"
  description = "Example Kendra index"
  role_arn    = aws_iam_role.kendra_role.arn
  edition = "DEVELOPER_EDITION" # or "ENTERPRISE_EDITION" based on your needs
}

# Kendra S3 Data Source
resource "aws_kendra_data_source" "example" {
  index_id = aws_kendra_index.example.id
  name     = "example-s3-data-source"
  type     = "S3"
  role_arn = aws_iam_role.kendra_role.arn

  configuration {
    s3_configuration {
      bucket_name = aws_s3_bucket.kendra_datasource.id
    }
  }
}

# IAM role for Kendra
resource "aws_iam_role" "kendra_role" {
  name = "kendra_role"

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

# IAM policy for Kendra
resource "aws_iam_role_policy" "kendra_policy" {
  name = "kendra_policy"
  role = aws_iam_role.kendra_role.id

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
          aws_s3_bucket.kendra_datasource.arn,
          "${aws_s3_bucket.kendra_datasource.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kendra:*"
        ]
        Resource = "*"
      }
    ]
  })
}

# Add these to the existing outputs
output "kendra_index_id" {
  description = "ID of the Kendra Index"
  value       = aws_kendra_index.example.id
}

output "kendra_datasource_id" {
  description = "ID of the Kendra Data Source"
  value       = aws_kendra_data_source.example.id
}


# Outputs
output "lambda_function_arn" {
  description = "ARN of the Lambda Function"
  value       = aws_lambda_function.function.arn
}

output "security_hub_event_rule_arn" {
  description = "ARN of the EventBridge rule"
  value       = aws_cloudwatch_event_rule.security_hub_event_rule.arn
}
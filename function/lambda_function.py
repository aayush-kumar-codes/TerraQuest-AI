from datetime import datetime, timedelta
import os
import logging
import boto3
import jsonpickle
import json

logger = logging.getLogger()
logger.setLevel(logging.INFO)

client = boto3.client('lambda')

bedrock_runtime = boto3.client('bedrock-runtime')
kendra = boto3.client('kendra')
securityhub = boto3.client('securityhub')


def get_index_id_by_name(index_name):

    # List all Kendra indexes
    response = kendra.list_indices()

    # Search for the index with the given name
    for index in response['IndexConfigurationSummaryItems']:
        print(index)
        if index['Name'] == index_name:
            return index['Id']

    # If the index is not found, return None or raise an exception
    return None  # or raise ValueError


def query_kendra(kendra_id, query):
    # Perform the search using Kendra
    response = kendra.query(
        IndexId=kendra_id,
        QueryText=query
    )

    # Extract relevant information from the response
    results = []
    for result in response['ResultItems']:
        document = {
            'id': result['DocumentId'],
            'title': result['DocumentTitle']['Text'],
            'excerpt': result['DocumentExcerpt']['Text'],
            'uri': result.get('DocumentURI', '')
        }
        results.append(document)

    return results


def process_prompt(system, prompt):

    body = json.dumps({
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 9186,
        "system": system,
        "messages": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "text",
                        "text": prompt
                    }
                ]
            }
        ]
    })

    response = bedrock_runtime.invoke_model(
        # modelId="anthropic.claude-3-sonnet-20240229-v1:0",
        modelId="amazon.titan-embed-text-v1",
        contentType="application/json",
        accept="application/json",
        body=body
    )

    response_body = json.loads(response['body'].read())
    logger.info(f"respone body from api {response_body}")
    return response_body['content'][0]['text']


def fetch_security_hub_findings():
    # Create a Security Hub client

    # Set up parameters for the get_findings API call
    params = {
        'MaxResults': 2,  # Adjust this value based on your needs
        'SortCriteria': [{'Field': 'UpdatedAt', 'SortOrder': 'DESC'}],
        'Filters': {
            'RecordState': [{'Value': 'ACTIVE', 'Comparison': 'EQUALS'}],
            'UpdatedAt': [{'Start': (datetime.now() - timedelta(days=30)).isoformat(), 'End': datetime.now().isoformat()}]
        }
    }

    findings = []
    max_finding = 2
    # Paginate through results
    while True:
        response = securityhub.get_findings(**params)
        findings.extend(response['Findings'])

        if (len(findings) > max_finding):
            break
        # Check if there are more findings to fetch
        if 'NextToken' not in response:
            break
        params['NextToken'] = response['NextToken']

    # Process and format the findings as needed
    formatted_findings = []
    for finding in findings:
        formatted_finding = {
            'Id': finding['Id'],
            'Title': finding['Title'],
            'Description': finding['Description'],
            'Severity': finding['Severity']['Label'],
            'ResourceType': finding['Resources'][0]['Type'] if finding['Resources'] else 'N/A',
            'UpdatedAt': finding['UpdatedAt']
        }
        formatted_findings.append(formatted_finding)

    return formatted_findings


def analyze_finding(kendra_id, event):
    user = f"""I want to search aws opensearch for related documents
    I want you to review findings from security hub and extract important keywords create a search summary
    <finding>
    {jsonpickle.encode(event)}
    </finding>

    Only return the final query in text format, don't mention anything else
    Create a query in natural language extracting important terms.

    The final search query should be less than 500 words.
    """
    search_query = process_prompt("", user)

    docs = query_kendra(kendra_id, search_query)
    logger.info('## KENDRA\r' + jsonpickle.encode(docs))
    system = f"""You are an AWS Security Engineer looking to improve the security posture of your organization

    Generate incident report in below format
    ==========================================

    AnyCompany Incident Response Runbook Template
    This playbook is provided as a template for AnyCompany Security Team using AWS products and to build our incident response capability. This template is customized to suit AnyCompany's particular needs, risks, available tools and work processes.

    This runbook outlines response steps for security incidents. This runbook is used to –
    • Gather evidence
    • Contain and then eradicate the incident
    • Recover from the incident
    • Conduct post-incident activities, including post-mortem and feedback processes

    Incident Summary

    Incident Type:

    Incident Description:

    Incident Response Process:

    1. Acquire, preserve, document evidence
    2. Determine the sensitivity, dependency of the resources
    3. Identify the remediation steps
    4. Verify and validate the changes in lower environment
    5. Confirm with respective application teams
    6. Make changes to resolve the incident
    7. Record history and actions
    8. Post activity - perform a root cause analysis, update policies if needed

    This report text will be finally saved in word format, so i need output in markdown format.
    Create a detailed report.

    """
    user = f"""Review the finding and summarize actionable next steps,
    <finding>
    {jsonpickle.encode(event)}
    </finding>

    This report text will be finally saved in word format, so i need output in markdown format.
    Create a detailed and in-depth report. 
    Provide output in proper markdown format with headings/bullet points etc.
    """

    response = process_prompt(system, user)
    return response, search_query, docs


def lambda_handler(event, context):
    # logger.info('## ENVIRONMENT VARIABLES\r' + jsonpickle.encode(dict(**os.environ)))
    logger.info('## EVENT\r' + jsonpickle.encode(event))
    # logger.info('## CONTEXT\r' + jsonpickle.encode(context))
    kendra_id = get_index_id_by_name("example-index")
    res = []
    if "local-test" not in jsonpickle.encode(event):
        for row in event['detail']["findings"]:
            response = analyze_finding(kendra_id, row)
            res.append({"doc": row, "response": response[0], "search_query": response[1], "kendra_docs": response[2]})
            # Generate Word document
            

            # Upload to S3
            s3 = boto3.client('s3')
            bucket_name = 'test-stack-saurabh'  # Replace with your S3 bucket name
            id = row['Id'].split("/")[-1]
            file_name = f'incident_report_{id}.md'
            # s3.upload_fileobj(doc_buffer, bucket_name, file_name)
            s3.put_object(Bucket=bucket_name, Key=file_name, Body=response[0])

            logger.info(f'Uploaded {file_name} to S3 bucket {bucket_name}')
    else:
        findings = fetch_security_hub_findings()
        for idx, row in enumerate(findings):
            response = analyze_finding(kendra_id, row)
            res.append({"doc": row, "response": response[0], "search_query": response[1], "kendra_docs": response[2]})
            # Generate Word document
            doc = markdown_to_docx(response[0])

            # Save document to BytesIO object
            doc_buffer = BytesIO()
            doc.save(doc_buffer)
            doc_buffer.seek(0)

            # Upload to S3
            s3 = boto3.client('s3')
            bucket_name = 'test-stack-saurabh'  # Replace with your S3 bucket name
            id = row['Id'].split("/")[-1]
            file_name = f'incident_report_{id}.docx'
            s3.upload_fileobj(doc_buffer, bucket_name, file_name)

            logger.info(f'Uploaded {file_name} to S3 bucket {bucket_name}')

    result = {
        'statusCode': 200,
        'response': response,
        'res': res,
    }
    return result

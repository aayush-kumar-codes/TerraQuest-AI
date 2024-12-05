from datetime import datetime, timedelta
import os
import logging
import boto3
import jsonpickle
import json

logger = logging.getLogger()
logger.setLevel(logging.INFO)

client = boto3.client('lambda')

bedrock = boto3.client('bedrock')
bedrock_runtime = boto3.client('bedrock-runtime')
kendra = boto3.client('kendra')
securityhub = boto3.client('securityhub')

USE_CLAUDE = True


def get_guardrail_id(guardrail_name):
    try:
        response = bedrock.list_guardrails()
        for guardrail in response['guardrails']:
            print("guardrail['name']", guardrail['name'])
            if guardrail['name'] == guardrail_name:
                print("guardrail", guardrail)
                return guardrail['arn']
        print(f"Guardrail '{guardrail_name}' not found.")
        return None
    except Exception as e:
        print(f"Error retrieving guardrail: {str(e)}")
        return None


def get_index_id_by_name(index_name):
    response = kendra.list_indices()
    for index in response['IndexConfigurationSummaryItems']:
        print(index)
        if index['Name'] == index_name:
            return index['Id']
    return None


def retrieve_kendra_documents(kendra_id, query, page_size=10, page_number=1):
    kendra = boto3.client('kendra')

    response = kendra.retrieve(
        IndexId=kendra_id,
        QueryText=query,
    )

    results = {
        'retrieved_documents': [],
        'warning': response.get('WarningMessage'),
        'page_size': page_size,
        'page_number': page_number,
    }

    for result in response['ResultItems']:
        document = {
            # 'id': result['DocumentId'],
            'title': result['DocumentTitle'],
            'content': result['Content'],
            # 'content_type': result['ContentType'],
            # 'attributes': result.get('Attributes', []),
            # 'document_uri': result.get('DocumentURI'),
            'document_attributes': result.get('DocumentAttributes', [])
        }
        results['retrieved_documents'].append(document)

    return results


def query_kendra(kendra_id, query):
    response = kendra.query(
        IndexId=kendra_id,
        QueryText=query
    )

    results = {
        'query_id': response.get('QueryId'),
        'total_results': response.get('TotalNumberOfResults'),
        'execution_time': response.get('QueryExecutionTime'),
        'suggested_queries': response.get('SuggestedQueries', []),
        'facets': response.get('FacetResults', []),
        'documents': []
    }

    for result in response['ResultItems']:
        document = {
            'id': result['DocumentId'],
            'title': result['DocumentTitle']['Text'],
            'excerpt': result['DocumentExcerpt']['Text'],
            'uri': result.get('DocumentURI', ''),
            'type': result['Type'],
            'score': result['ScoreAttributes']['ScoreConfidence'],
            # 'feedback_token': result.get('FeedbackToken'),
            # 'attributes': result.get('DocumentAttributes', []),
            # 'additional_attributes': result.get('AdditionalAttributes', [])
        }
        results['documents'].append(document)

    if 'WarningMessage' in response:
        results['warning'] = response['WarningMessage']

    return results


def process_prompt(system, prompt, guardrail_id):

    if USE_CLAUDE:
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
            modelId="anthropic.claude-3-haiku-20240307-v1:0",  # ,"anthropic.claude-3-sonnet-20240229-v1:0",
            contentType="application/json",
            accept="application/json",
            body=body,
            guardrailIdentifier=guardrail_id,
            guardrailVersion="DRAFT"
        )

        response_body = json.loads(response['body'].read())
        logger.info(f"respone body from api {response_body}")
        return response_body['content'][0]['text']
    else:
        print(f"prompt {prompt}")
        body = json.dumps({"inputText": system + "\n" + prompt, "textGenerationConfig": {"maxTokenCount": 4096, "stopSequences": [], "temperature": 0, "topP": 1}})

        response = bedrock_runtime.invoke_model(
            modelId="amazon.titan-text-lite-v1",
            contentType="application/json",
            accept="application/json",
            body=body

        )

        response_body = json.loads(response['body'].read())
        logger.info(f"respone body from api {response_body}")
        return response_body["results"][0]['outputText']


def do_qa_with_context(context, query, guardrail_id):
    system = f""""""
    user = f"""The following is a friendly conversation between a human and an AI.
    The AI is talkative and provides lots of specific details from its context.
    If the AI does not know the answer to a question, it truthfully says it
    does not know.
    <context>
    {context}
    </context>
    Instruction: Based on the above documents, provide a detailed answer for, {query}
    Answer "don't know" if not present in the document.
    Also provide document title and page number if any document is used from the context to the answer the question.
    Solution:"""

    response = process_prompt(system, user, guardrail_id)
    return response


def generate_final_reply(input, chat_history, context, guardrail_id):
    system = f""""""
    user = f"""The following is a friendly conversation between a human and an AI.

    Chat History:
    {chat_history}

    Context: {context}

    Follow Up Input: {input}


    Generate a final response for the user based on chat history, context and the follow up input which the user has asked.

    Response:"""

    response = process_prompt(system, user, guardrail_id)
    return response


def generate_query(input, chat_history, guardrail_id):
    condense_qa_template = f"""Given the following conversation and a follow up question, rephrase the follow up question
        to be a standalone question.

        Chat History:
        {chat_history}
        Follow Up Input: {input}
        Standalone question:"""

    response = process_prompt("", condense_qa_template, guardrail_id)
    return response


def lex_format_response(event, response_text, chat_history, guardrail_id):
    event['sessionState']['intent']['state'] = "Fulfilled"
    return {
        'sessionState': {
            'sessionAttributes': {'chat_history': chat_history},
            'dialogAction': {
                'type': 'Close'
            },
            'intent': event['sessionState']['intent']
        },
        'messages': [{'contentType': 'PlainText', 'content': response_text}],
        'sessionId': event['sessionId'],
        'requestAttributes': event['requestAttributes'] if 'requestAttributes' in event else None,
        'guardrail_id': guardrail_id,
    }


def lambda_handler(event, context):
    logger.info('## ENVIRONMENT VARIABLES\r' + jsonpickle.encode(dict(**os.environ)))
    logger.info('## EVENT\r' + jsonpickle.encode(event))
    logger.info('## CONTEXT\r' + jsonpickle.encode(context))

    env = dict(**os.environ)

    guardrail_id = get_guardrail_id("PII-Masking-Guardrail")

    chat_history_str = ""
    response_text = ""
    if (event['inputTranscript']):
        user_input = event['inputTranscript']
        prev_session = event['sessionState']['sessionAttributes']

        print(prev_session)

        if 'chat_history' in prev_session:
            chat_history = list(tuple(pair) for pair in json.loads(prev_session['chat_history']))
        else:
            chat_history = []

        chat_history_str = "\n".join(f"{user}: {message}" for user, message in chat_history)

        generated_query_text = generate_query(user_input, chat_history, guardrail_id)

        print("user input", user_input)
        print("chat history", chat_history_str)

        kendra_id = env["KENDRA_INDEX_ID"]
        kendra_index_name = env["KENDRA_INDEX_NAME"]

        # kendra_id = get_index_id_by_name("example-index")

        # response = analyze_finding(kendra_id, "test123")
        # docs = query_kendra(kendra_id, query)
        docs = retrieve_kendra_documents(kendra_id=kendra_id, query=generated_query_text)
        context = ""
        for doc in docs["retrieved_documents"]:
            context += f"""
            <document>
                {jsonpickle.encode(doc)}
            </document>
            """

        response = do_qa_with_context(context=context, query=generated_query_text, guardrail_id=guardrail_id)
        response_text = generate_final_reply(chat_history=chat_history, input=user_input, context=response, guardrail_id=guardrail_id)

    # Append user input and response to chat history. Then only retain last 3 message histories.
    # It seemed to work better with AI responses removed, but try adding them back in. {response_text}
    chat_history.append((f"{user_input}", f"..."))
    chat_history = chat_history[-3:]

    return lex_format_response(event, response_text, json.dumps(chat_history), guardrail_id=guardrail_id)

    # result = {
    #     "kendra_id": kendra_id,
    #     "kendra_index_name": kendra_index_name,
    #     "docs2": docs,
    #     "response": response,
    #     "query": query,
    #     "generated_query": generated_query,
    #     # "context": context,
    # }
    # return result

#!/bin/bash
set -eo pipefail
rm -rf function/package
rm -rf layer/
cd function

# docker run --platform linux/amd64 -v "$PWD":/var/task "lambci/lambda:build-python3.8" /bin/sh -c "pip install --upgrade -r requirements.txt --target ./package/python; exit"

docker run --platform linux/amd64 -v "$PWD":/var/task "lambci/lambda:build-python3.8" /bin/sh -c "pip install --upgrade -r requirements.txt --target ./layer/python/lib/python3.8/site-packages/; exit"
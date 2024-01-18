#! /bin/bash

set -e

if [ -z "$CLUSTER_NAME" ]; then
    echo "CLUSTER_NAME is not set"
    exit 1
fi

export SP_CLUSTER_NAME="sp-$CLUSTER_NAME"

sp_for_cluster = $(az ad sp create-for-rbac --name $SP_CLUSTER_NAME --skip-assignment --json-auth)

# TODO Get Object ID and stuff


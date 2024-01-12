#! /bin/bash

set -e

# :: TODO ::

# Create secondary self-signed root cert authority
# --Insecure is used to skip the prompt for the root cert password, do not use in production
echo "Creating secondary root and intermediate CA certs"
step certificate create --profile root-ca "Secondary Root CA Demo" \
    ./temp/secondary_root_ca.crt ./temp/secondary_root_ca.key \
    --not-after 24h --no-password --insecure

# Create a secondary intermediary CA Cert and key signed by the root cert
step certificate create --profile intermediate-ca "secondary Intermediate CA Demo" \
    ./temp/secondary_intermediate_ca.crt ./temp/secondary_intermediate_ca.key \
    --ca ./temp/secondary_root_ca.crt --ca-key ./temp/secondary_root_ca.key \
    --not-after 24h --no-password --insecure

# Update the secret to contain the new root CA cert
echo "Updating the 'aio-ca-key-pair-test-only' secret to contain the new root CA cert"
kubectl create secret tls aio-ca-key-pair-test-only -n $DEFAULT_NAMESPACE \
    --save-config \
    --dry-run=client \
    --cert=./temp/secondary_root_ca.crt --key=./temp/secondary_root_ca.key \
    -o yaml | \
    kubectl apply -f -

# Update the Trust Bundle to contain the old and the new cert chain during the rotation

# Update the client pods to pick the new configmap before the rotation

# Update the secret for the Issuer to contain the new root CA cert
# Check if issuer detects a change in secret value to assign a new cert to the broker automatically

# Update the server side - restart MQ pods to pick up the new secret for Issuer


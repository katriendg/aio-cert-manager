#! /bin/bash

set -e

# check if the required environment variables are set
if [ -z "$DEFAULT_NAMESPACE" ]; then
    echo "DEFAULT_NAMESPACE is not set"
    exit 1
fi
if [ -z "$AIO_TRUST_CONFIG_MAP_KEY" ]; then
    echo "AIO_TRUST_CONFIG_MAP_KEY is not set"
    exit 1
fi
if [ -z "$PRIMARY_CA_KEY_PAIR_SECRET_NAME" ]; then
    echo "PRIMARY_CA_KEY_PAIR_SECRET_NAME is not set"
    exit 1
fi
if [ -z "$AIO_TRUST_CONFIG_MAP" ]; then
    echo "AIO_TRUST_CONFIG_MAP is not set"
    exit 1
fi
if [ -z "$WORKLOAD_NAMESPACE" ]; then
    echo "WORKLOAD_NAMESPACE is not set"
    exit 1
fi

# ================================================================== #
# USE THIS SAMPLE IN CONJUNCTION WITH 2-1-aio-init.sh which does not use trust-manager
# This script only affects the cluster and does not change any Azure resources
# On Disk:
# - creates a local self signed CA cert root, key and chain - primary root
# On the cluster:
#  - creates configmaps and secrets for AIO
#  - creates a workload namespace and validates the trust bundle configmap gets copied over
# ================================================================== #

# Variables
scriptPath=$(dirname $0)

# Create secondary self-signed root cert authority
echo "Creating secondary root CA certs"
>./temp/certs/ca-secondary.conf cat <<EOF
[ req ]
distinguished_name = req_distinguished_name
prompt = no
x509_extensions = v3_ca

[ req_distinguished_name ]
CN=Azure IoT Operations Demo Secondary Root CA - Dev Only

[ v3_ca ]
basicConstraints = critical, CA:TRUE
keyUsage = keyCertSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
EOF
openssl ecparam -name prime256v1 -genkey -noout -out ./temp/certs/ca-secondary-cert-key.pem
openssl req -new -x509 -key ./temp/certs/ca-secondary-cert-key.pem -days 30 -config ./temp/certs/ca-secondary.conf -out ./temp/certs/ca-secondary-cert.pem
rm ./temp/certs/ca-secondary.conf

# Chain together the two certs for trust
cat  ./temp/certs/ca-secondary-cert.pem ./temp/certs/ca-primary-cert.pem > ./temp/certs/ca-two-certs.pem

# Update the trust configmap with the new chain
echo "Updating trust configmap with the new chain"
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: $AIO_TRUST_CONFIG_MAP
  namespace: $DEFAULT_NAMESPACE
data:
  $AIO_TRUST_CONFIG_MAP_KEY: |
$(cat ./temp/certs/ca-two-certs.pem | sed 's/^/      /')
EOF

# Sync the configmap to the workload namespace
echo "Updating trust configmap with the new chain - workload namespece"
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: $AIO_TRUST_CONFIG_MAP
  namespace: $WORKLOAD_NAMESPACE
data:
  $AIO_TRUST_CONFIG_MAP_KEY: |
$(cat ./temp/certs/ca-two-certs.pem | sed 's/^/      /')
EOF

# Wait a few seconds for the pods to pick up the new configmap, and restart those that will not automatically do so
sleep 10

# TLS secret update - secondary key pair as content
echo "Updating secret with secondary key pair"
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $PRIMARY_CA_KEY_PAIR_SECRET_NAME
  namespace: $DEFAULT_NAMESPACE
type: kubernetes.io/tls
data:
  tls.crt: $(cat ./temp/certs/ca-secondary-cert.pem | base64 | tr -d '\n')
  tls.key: $(cat ./temp/certs/ca-secondary-cert-key.pem | base64 | tr -d '\n')
EOF

# Check the contents of the tls.crt key in the secret
echo "Checking the contents of the tls.crt key in the secret"
kubectl get secret $PRIMARY_CA_KEY_PAIR_SECRET_NAME -n $DEFAULT_NAMESPACE -o jsonpath='{.data.tls\.crt}' | base64 --decode

# Use cmctl CLI to renew the certs using the same secret
cmctl renew --namespace=azure-iot-operations --all
sleep 10 # wait for the new cert to be issued
# Get all events that have to do with certificate issuing
kubectl get events | grep -E 'issu(er|ed|ing)'

# Update the client pods to pick the new configmap before the rotation (for testing, Mosquitto Pod can be used)
# Delay for the sync of the new configmap to the pods depends on configuration of kubelet and cache propagation delay
#  https://kubernetes.io/docs/concepts/configuration/configmap/#mounted-configmaps-are-updated-automatically

# For OPC Supervisor, restart the pod to pick up the new configmap, this does not happen automatically
# restart OPC UA with new trust bundle CM name
kubectl rollout restart deployment/aio-opc-supervisor -n $DEFAULT_NAMESPACE

# TODO - in future for other clients such as Data processor, KafkaConnector, etc - TODO

# connect locally to the broker and check the new cert is used
echo "Publishing a new MQTT message to the broker using secondary CA bundle, should be successful"
mosquitto_pub -h localhost -p 8883 -m "hello-loc-secondary" -t "testcerts" -d --cafile ./temp/certs/ca-two-certs.pem

echo "Finished rollover to secondary root CA key pair and trust bundle"

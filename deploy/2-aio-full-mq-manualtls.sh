#! /bin/bash

set -e

# ================================================================== #
# Before running this script:
#  - ensure you have loaded the environment variables as described in the README, 
#       skip the variables starting with 'AKV_SP_' because this script creates the SP
#  - run ./deploy/1-arc-connect.sh to connect your cluster to Arc
#
# This script deploys Azure Key Vault, full AIO using the default CLI, including Service Principal
# Base on the default setup, it generates:
# - Certs: a self signed root cert, Intermediate CA and a server cert for MQTT broker
# - MQ BrokerListener: additional listener with TLS using custom certs
# - Secrets for server cert
# - Trust bundle in configmap for the distribution of root cert
# - Mosquitto client Pod with mount to the custom root trust bundle
# ================================================================== #

if [ -z "$CLUSTER_NAME" ]; then
    echo "CLUSTER_NAME is not set"
    exit 1
fi
if [ -z "$RESOURCE_GROUP" ]; then
    echo "RESOURCE_GROUP is not set"
    exit 1
fi
if [ -z "$LOCATION" ]; then
    echo "LOCATION is not set"
    exit 1
fi
if [ -z "$AKV_NAME" ]; then
    echo "AKV_NAME is not set"
    exit 1
fi

# Variables
scriptPath=$(dirname $0)
rootCAfile=./temp/certs/step_root_ca.crt
rootCAkey=./temp/certs/step_root_ca.key
intermediateCAfile=./temp/certs/stepintermediate_ca.crt
intermediateCAkey=./temp/certs/stepintermediate_ca.key
serverCertFile=./temp/certs/stepmqtts-endpoint.crt
serverKeyFile=./temp/certs/stepmqtts-endpoint.key
serverChainFile=./temp/certs/server_chain.pem

# Check if /temp folder exists and create if missing
if [ ! -d "./temp" ]; then
    mkdir ./temp
fi
if [ ! -d "./temp/certs" ]; then
    mkdir ./temp/certs
fi

# Create Key Vault
echo "Create Key Vault"
az keyvault create -n $AKV_NAME -g $RESOURCE_GROUP --enable-rbac-authorization false
keyVaultResourceId=$(az keyvault show -n $AKV_NAME -g $RESOURCE_GROUP -o tsv --query id)

# Deploy AIO
az iot ops init --cluster $CLUSTER_NAME -g $RESOURCE_GROUP  \
  --kv-id $keyVaultResourceId \
  --mq-mode auto --simulate-plc

# Check Broker is running - when using CLI to deploy AIO, the broker is named 'broker'
status=$(kubectl get broker broker -n $DEFAULT_NAMESPACE -o json | jq '.status.status')
while [ "$status" != "\"Running\"" ]
do
    echo "Waiting for broker to be running"
    sleep 5
    status=$(kubectl get broker broker -n $DEFAULT_NAMESPACE -o json | jq '.status.status')
done

echo "Creating custom root CA cert for MQ manual TLS"
step certificate create --profile root-ca "Manual MQ Root CA" $rootCAfile $rootCAkey \
  --no-password --insecure

step certificate create --profile intermediate-ca "Manual MQ Intermediate CA" $intermediateCAfile $intermediateCAkey \
--ca $rootCAfile --ca-key $rootCAkey --no-password --insecure

step certificate create mqtts-endpoint $serverCertFile $serverKeyFile \
--profile leaf \
--not-after 8760h \
--san mqtts-endpoint \
--san mqtts-endpoint.azure-iot-operations \
--san mqtts-endpoint.azure-iot-operations.svc.cluster.local \
--san localhost \
--ca $intermediateCAfile --ca-key $intermediateCAkey \
--no-password --insecure
# note added '--san localhost' for local developer inner loop testing purposes

# Generate a chain file for the server cert, endpoint as the first entry, intermediate as the second
cat  $serverCertFile $intermediateCAfile  > $serverChainFile

echo "Creating a secret 'mq-server-cert-secret' for the server cert"
kubectl create secret tls mq-server-cert-secret -n azure-iot-operations \
  --cert $serverChainFile \
  --key $serverKeyFile

kubectl apply -f - <<EOF
apiVersion: mq.iotoperations.azure.com/v1beta1
kind: BrokerListener
metadata:
  name: manual-tls-listener
  namespace: azure-iot-operations
spec:
  brokerRef: broker
  authenticationEnabled: false # If true, BrokerAuthentication must be configured
  authorizationEnabled: false
  serviceType: loadBalancer # CLI AIO deployments adds a clusterIP service for the default listener, needs to be different
  serviceName: mqtts-endpoint # Match the SAN in the server certificate
  port: 8884 # Avoid port conflict with default listener at 8883
  tls:
    manual:
      secretName: mq-server-cert-secret # point to the secret with the server cert
EOF

# TLS configmap for trust bundle with Manual MQ Root CA in azure-iot-operations namespace
echo "Creating ConfigMap for Manual MQ TLS root CA to be used by trust manager"
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cm-step-root-ca
  namespace: $DEFAULT_NAMESPACE
data:
  $AIO_TRUST_CONFIG_MAP_KEY: |
$(cat $rootCAfile | sed 's/^/      /')
EOF

# Install trust-manager
helm repo add jetstack https://charts.jetstack.io --force-update
helm upgrade -i -n $DEFAULT_NAMESPACE trust-manager jetstack/trust-manager --set-string app.trust.namespace=$DEFAULT_NAMESPACE  --wait

# Create a trust bundle for the manual MQ root CA and the default aio trust bundle
kubectl apply -f - <<EOF
apiVersion: trust.cert-manager.io/v1alpha1
kind: Bundle
metadata:
  name: cm-default-manual-mq-trust-bundle
  namespace: $DEFAULT_NAMESPACE
spec:
  sources:
  - useDefaultCAs: false
  - configMap:
      name: cm-step-root-ca
      key: "$AIO_TRUST_CONFIG_MAP_KEY"
  - configMap:
      # Include the default AIO configmap trust bundle
      name: $AIO_TRUST_CONFIG_MAP
      key: "$AIO_TRUST_CONFIG_MAP_KEY"
  target:
    configMap:
      key: "$AIO_TRUST_CONFIG_MAP_KEY"
    namespaceSelector:
      matchLabels:
        trust: enabled
EOF

# Create a workload namespace for the mosquitto client
echo "Creating the '$WORKLOAD_NAMESPACE' namespace"
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  labels:
    trust: enabled
  name: $WORKLOAD_NAMESPACE
EOF

echo "Create the trust bundle ConfigMap 'cm-default-manual-mq-trust-bundle' in $WORKLOAD_NAMESPACE"
kubectl get configmap -n $WORKLOAD_NAMESPACE

echo "Checking if the new MQ listener SVC endpoint is exposed"
kubectl get svc -n $DEFAULT_NAMESPACE | grep mqtts-endpoint

# Deploy mosquitto client with a mount to the trust bundle
kubectl create serviceaccount mqtt-client -n $WORKLOAD_NAMESPACE
kubectl apply -f $scriptPath/yaml/mosquitto_client-manualtls.yaml

echo "Finished deploying AIO with CLI, Mosquitto client, MQ custom listener with manual TLS and certs"
echo "    "
echo "To test the setup, you can run the following:"
echo "    "
echo "-- Exec into the Mdsquitto client pod ---"
echo "kubectl exec --stdin --tty mosquitto-client-manualtls -n $WORKLOAD_NAMESPACE -- sh"
echo "-- List the contents of the mounted configmap with trust bundles ---"
echo "cat /var/run/certs/ca.crt"
echo "-- To Publish a new message to MQ using the new listener on port 8884 ---"
echo "mosquitto_pub -h mqtts-endpoint.azure-iot-operations -p 8884 -m 'hello through 8884' -t 'mytopic' -d --cafile /var/run/certs/ca.crt"
echo "--END--"
#! /bin/bash

set -e

# ================================================================== #
# This script deploys minimal AIO extensions with the CLI
# And sets up MQ and a Mosquitto client Pod for testing
# ================================================================== #

# check if the required environment variables are set
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
if [ -z "$AIO_TRUST_CONFIG_MAP" ]; then
    echo "AIO_TRUST_CONFIG_MAP is not set"
    exit 1
fi

randomValue=$RANDOM
deploymentName="aio-deployment-$randomValue"
scriptPath=$(dirname $(dirname $0))

echo "Deploying AIO via ARM template to cluster $CLUSTER_NAME in resource group $RESOURCE_GROUP"

az deployment group create \
    --resource-group $RESOURCE_GROUP \
    --name aio-deployment-$deploymentName \
    --template-file "$scriptPath/arm/aio2previewminimal.json" \
    --parameters clusterName=$CLUSTER_NAME \
    --parameters location=$LOCATION \
    --parameters clusterLocation=$LOCATION \
    --verbose --no-prompt

echo "Setting kube namespace context to azure-iot-operations"
kubectl config set-context --current --namespace=azure-iot-operations

# Deploy MQ Broker, Listener and Diagnostics
echo "deploying MQ Broker, Listener and Diagnostics"
kubectl apply -f $scriptPath/yaml/cert-issuer-primary.yaml
kubectl apply -f $scriptPath/yaml/mq-broker-base.yaml
kubectl apply -f $scriptPath/yaml/mq-broker-listener-primary.yaml

# Check for deployment of MQ Broker
kubectl get broker --namespace azure-iot-operations

# Check for running status of broker named 'mq-instance-broker'
status=$(kubectl get broker mq-instance-broker -o json | jq '.status.status')
while [ "$status" != "\"Running\"" ]
do
    echo "Waiting for broker to be running"
    sleep 5
    status=$(kubectl get broker mq-instance-broker -o json | jq '.status.status')
done

# Deploy Mosquitto client for testing
kubectl create serviceaccount mqtt-client -n $WORKLOAD_NAMESPACE
kubectl apply -f $scriptPath/yaml/mosquitto_client.yaml

# Deploy OPC UA with simulator
helm upgrade -i opcuabroker oci://mcr.microsoft.com/opcuabroker/helmchart/microsoft-iotoperations-opcuabroker \
    --set image.registry=mcr.microsoft.com     \
    --version 0.3.0-preview.3   \
    --namespace azure-iot-operations    \
    --create-namespace     \
    --set secrets.kind=k8s     \
    --set secrets.csiServicePrincipalSecretRef=aio-akv-sp \
    --set secrets.csiDriver=secrets-store.csi.k8s.io \
    --set mqttBroker.address=mqtts://aio-mq-dmqtt-frontend.azure-iot-operations.svc.cluster.local:8883     \
    --set mqttBroker.authenticationMethod=serviceAccountToken \
    --set mqttBroker.serviceAccountTokenAudience=aio-mq     \
    --set mqttBroker.caCertConfigMapRef=${AIO_TRUST_CONFIG_MAP}   \
    --set mqttBroker.caCertKey=${AIO_TRUST_CONFIG_MAP_KEY} \
    --set opcPlcSimulation.autoAcceptUntrustedCertificates=true \
    --set connectUserProperties.metriccategory=aio-opc     \
    --set opcPlcSimulation.deploy=true     \
    --wait

helm upgrade -i aio-opcplc-connector oci://mcr.microsoft.com/opcuabroker/helmchart/aio-opc-opcua-connector \
    --version 0.3.0-preview.3 \
    --namespace azure-iot-operations \
    --set opcUaConnector.settings.discoveryUrl="opc.tcp://opcplc-000000.azure-iot-operations.svc.cluster.local:50000" \
    --set opcUaConnector.settings.autoAcceptUntrustedCertificates=true \
    --wait

kubectl apply -f $scriptPath/yaml/assettypes.yaml
kubectl apply -f $scriptPath/yaml/assets.yaml

echo "Finished deploying AIO components with an intermediate primary cert chain"
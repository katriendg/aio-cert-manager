#! /bin/bash

set -e

# ================================================================== #
# Script based on https://github.com/Azure/azure-iot-operations/blob/main/tools/setup-cluster/setup-cluster.sh
# som modifications to setup CA and trust manager
# This script deploys Azure Key Vault, sets policies for AKV in Azure 
# On the cluster:
#  - enables Arc Extension KV CSI Driver
#  - creates a local self signed cert root, key and chain
#  - passes the key and chain to the AZ iot opt init command
# For simplicity the CLI az iot ops init --no-deploy is used
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
if [ -z "$AKV_SP_CLIENT_ID" ]; then
    echo "AKV_SP_CLIENT_ID is not set"
    exit 1
fi
if [ -z "$AKV_SP_CLIENT_SECRET" ]; then
    echo "AKV_SP_CLIENT_SECRET is not set"
    exit 1
fi

# Vars
AKV_SECRET_PROVIDER_NAME=akvsecretsprovider
AKV_PROVIDER_POLLING_INTERVAL=1h
DEFAULT_NAMESPACE=azure-iot-operations
PLACEHOLDER_SECRET_NAME=PlaceholderSecret

# Check if /temp folder exists and create if missing
if [ ! -d "./temp" ]; then
    mkdir ./temp
fi
if [ ! -d "./temp/certs" ]; then
    mkdir ./temp/certs
fi

echo "Creating root and intermediate CA certs"
# Create self-signed root cert authority

##############################################################################
# The below commands will create the test CA certificate used to encrypt     #
# traffic in the cluster.                                                    #
##############################################################################
>./temp/certs/ca-primary.conf cat <<-EOF
[ req ]
distinguished_name = req_distinguished_name
prompt = no
x509_extensions = v3_ca

[ req_distinguished_name ]
CN=Azure IoT Operations Quickstart Root CA - Not for Production

[ v3_ca ]
basicConstraints = critical, CA:TRUE
keyUsage = keyCertSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
EOF
openssl ecparam -name prime256v1 -genkey -noout -out ./temp/certs/ca-primary-cert-key.pem
openssl req -new -x509 -key ./temp/certs/ca-primary-cert-key.pem -days 30 -config ./temp/certs/ca-primary.conf -out ./temp/certs/ca-primary-cert.pem
rm ./temp/certs/ca-primary.conf

# Create Key Vault
echo "Create Key Vault and set a placeholder secret"
az keyvault create -n $AKV_NAME -g $RESOURCE_GROUP --enable-rbac-authorization false
keyVaultResourceId=$(az keyvault show -n $AKV_NAME -g $RESOURCE_GROUP -o tsv --query id)

# Set AKV policy for AKV Service Principal
echo "Setting AKV policy"
az keyvault set-policy -n $AKV_NAME -g $RESOURCE_GROUP --object-id $AKV_SP_OBJECT_ID \
    --secret-permissions get list \
    --key-permissions get list

# placeholder setup needed if AZ CLI not used below
az keyvault secret set --vault-name $AKV_NAME -n $PLACEHOLDER_SECRET_NAME --value "placeholder"

# Configure the Key Vault Extension on the Arc enabled cluster, create secret for cert, kv and configmaps
# :: Not used as we use manual creation of all components and arc extension installation
# az iot ops init --cluster $CLUSTER_NAME -g $RESOURCE_GROUP --kv-id $keyVaultResourceId \
#     --ca-file ./temp/certs/ca-primary-cert.pem \
#     --ca-key-file ./temp/certs/ca-primary-cert-key.pem \
#     --sp-app-id $AKV_SP_CLIENT_ID \
#     --sp-object-id $AKV_SP_OBJECT_ID \
#     --sp-secret "$AKV_SP_CLIENT_SECRET" \
#     --no-deploy

# Instead install CSI driver extension, ns, secrets and configmaps manually
echo "Adding the AKV Provider CSI Driver"
az k8s-extension create --cluster-name $CLUSTER_NAME --resource-group $RESOURCE_GROUP \
--cluster-type connectedClusters \
--extension-type Microsoft.AzureKeyVaultSecretsProvider \
--name $AKV_SECRET_PROVIDER_NAME \
--configuration-settings secrets-store-csi-driver.enableSecretRotation=true secrets-store-csi-driver.rotationPollInterval=$AKV_PROVIDER_POLLING_INTERVAL secrets-store-csi-driver.syncSecret.enabled=false

echo "Check if AKV extension is installed"
kubectl get pods -n kube-system

echo "Creating the '$DEFAULT_NAMESPACE' namespace"
if kubectl get namespace "$DEFAULT_NAMESPACE" &> /dev/null; then
    echo "Namespace "$DEFAULT_NAMESPACE" already exists"
else
    kubectl create namespace $DEFAULT_NAMESPACE
fi

echo "Adding AKV SP secret 'aio-akv-sp' in the namespace"
kubectl create secret generic aio-akv-sp --from-literal clientid="$AKV_SP_CLIENT_ID" --from-literal clientsecret="$AKV_SP_CLIENTSECRET" --namespace $DEFAULT_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
kubectl label secret aio-akv-sp secrets-store.csi.k8s.io/used=true --namespace $DEFAULT_NAMESPACE

##############################################################################
# The below command will create the four required SecretProviderClasses into #
# the cluster, referencing the Placeholder Secret from AKV.                  #
#                                                                            #
#    !!! DO NOT CHANGE THE NAMES OF ANY OF THE SECRETPROVIDERCLASSES !!!     #
#                                                                            #
##############################################################################
echo "Creating Azure IoT Operations Default SecretProviderClass"
kubectl apply -f - <<EOF
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: aio-default-spc
  namespace: $DEFAULT_NAMESPACE
spec:
  provider: "azure"
  parameters:
    usePodIdentity: "false"
    keyvaultName: "$AKV_NAME"
    objects: |
      array:
        - |
          objectName: $PLACEHOLDER_SECRET_NAME
          objectType: secret
          objectVersion: ""
    tenantId: $TENANT_ID
EOF

echo "Creating Azure IoT Operations OPC-UA SecretProviderClasses"
kubectl apply -f - <<EOF
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: aio-opc-ua-broker-client-certificate
  namespace: $DEFAULT_NAMESPACE
spec:
  provider: "azure"
  parameters:
    usePodIdentity: "false"
    keyvaultName: "$AKV_NAME"
    objects: |
      array:
        - |
          objectName: $PLACEHOLDER_SECRET_NAME
          objectType: secret
          objectVersion: ""
    tenantId: $TENANT_ID
EOF


kubectl apply -f - <<EOF
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: aio-opc-ua-broker-user-authentication
  namespace: $DEFAULT_NAMESPACE
spec:
  provider: "azure"
  parameters:
    usePodIdentity: "false"
    keyvaultName: "$AKV_NAME"
    objects: |
      array:
        - |
          objectName: $PLACEHOLDER_SECRET_NAME
          objectType: secret
          objectVersion: ""
    tenantId: $TENANT_ID
EOF

kubectl apply -f - <<EOF
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: aio-opc-ua-broker-trust-list
  namespace: $DEFAULT_NAMESPACE
spec:
  provider: "azure"
  parameters:
    usePodIdentity: "false"
    keyvaultName: "$AKV_NAME"
    objects: |
      array:
        - |
          objectName: $PLACEHOLDER_SECRET_NAME
          objectType: secret
          objectVersion: ""
    tenantId: $TENANT_ID
EOF

if kubectl get secret aio-ca-key-pair-test-only -n $DEFAULT_NAMESPACE &> /dev/null; then
	echo "TLS Secret aio-ca-key-pair-test-only already exists"
else
	kubectl create secret tls aio-ca-key-pair-test-only --cert=./temp/certs/ca-primary-cert.pem --key=./temp/certs/ca-primary-cert-key.pem --namespace $DEFAULT_NAMESPACE	
fi

if kubectl get cm aio-ca-trust-bundle-test-only -n $DEFAULT_NAMESPACE &> /dev/null; then
	echo "Certificate manager aio-ca-trust-bundle-test-only already exists"
else
	kubectl create cm aio-ca-trust-bundle-test-only --from-file=ca.crt=./temp/certs/ca-primary-cert.pem --namespace $DEFAULT_NAMESPACE
fi

echo "Check azure-iot-operations namespace has secrets and configmaps"
kubectl get secret -n $DEFAULT_NAMESPACE
kubectl get configmap -n $DEFAULT_NAMESPACE

# :: TODO :: Setup the trust-manager stuff here
echo "Trust manager setup"
# for now deploy into azure-iot-operations namespace
helm repo add jetstack https://charts.jetstack.io --force-update
helm upgrade -i -n azure-iot-operations trust-manager jetstack/trust-manager --wait


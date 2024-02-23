#! /bin/bash

set -e

# ================================================================== #
# Script based on https://github.com/Azure/azure-iot-operations/blob/main/tools/setup-cluster/setup-cluster.sh
# USE THIS SAMPLE IN CONJUNCTION WITH ./deploy/kv-intermediate/4-aio-cert-secondary.sh 
# some modifications to setup CA and trust configmap
# This script deploys Azure Key Vault, sets policies for AKV in Azure 
#  - on disk: creates a local self signed CA cert root, Intermediate CA, key and chain - primary root and intermediate
#  - uploads the Primary Root CA, Key, Intermediate CA key and chain to a Key Vault Secret
#  - creates  KV secret for a secondary root CA
# On the cluster:
#  - enables Arc Extension KV CSI Driver, note the polling interval is set to 1 minute
#  - creates configmap for trust bundle
#  - creates a pod that is used for mounting the the Key vault CSI driver and sync the secret to the cluster
#  - creates a workload namespace and uses trust manager to copy trust configmap over
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
if [ -z "$TENANT_ID" ]; then
    echo "TENANT_ID is not set"
    exit 1
fi
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

# Variables
AKV_SECRET_PROVIDER_NAME=akvsecretsprovider
AKV_PROVIDER_POLLING_INTERVAL=1m
PLACEHOLDER_SECRET_NAME=PlaceholderSecret

# Check if /temp folder exists and create if missing
if [ ! -d "./temp" ]; then
    mkdir ./temp
fi
if [ ! -d "./temp/certs" ]; then
    mkdir ./temp/certs
fi

echo "Creating root CA cert"
# # Create self-signed root cert authority
# ##############################################################################
# # The below commands will create the test CA certificate used to encrypt     #
# # traffic in the cluster.                                                    #
# ##############################################################################

# Cert file names
intermediateCertFileName="./temp/certs/ca-primary-intermediate.crt"
intermediateKeyFileName="./temp/certs/ca-primary-intermediate.key"
rootCertFileName="./temp/certs/ca-primary.crt"
rootKeyFileName="./temp/certs/ca-primary-cert.key"
rootIntermediateCertChainFileName="./temp/certs/intermediate-chain.crt"

# Key Vault secret names
rootCaKvSecretsNamePreFix="aio-root-ca"
intermediateCaKvSecretsNamePreFix="aio-intermediate-ca"

# Create root CA cert
step certificate create --profile root-ca "AIO Root CA - Dev Only" $rootCertFileName $rootKeyFileName \
  --no-password --insecure --not-after 8760h # 365 days

# Create intermedia CA cert
step certificate create "AIO Intermediate CA - Dev Only"  $intermediateCertFileName $intermediateKeyFileName \
        --profile intermediate-ca --ca $rootCertFileName --ca-key $rootKeyFileName \
        --no-password --insecure --not-after 2184h  # 91 days

# Chain the intermediate and root certs together and save to file on disk
cat $intermediateCertFileName $rootCertFileName > $rootIntermediateCertChainFileName

# Verify the certs
echo "Verifying the certs"
openssl verify -CAfile $rootCertFileName $rootIntermediateCertChainFileName
openssl x509 -noout -text -in $rootIntermediateCertChainFileName

# Create Key Vault
echo "Create Key Vault and set a placeholder secret"
az keyvault create -n $AKV_NAME -g $RESOURCE_GROUP --enable-rbac-authorization false
keyVaultResourceId=$(az keyvault show -n $AKV_NAME -g $RESOURCE_GROUP -o tsv --query id)

# Set AKV policy for AKV Service Principal
echo "Setting AKV policy"
az keyvault set-policy -n $AKV_NAME -g $RESOURCE_GROUP --object-id $AKV_SP_OBJECT_ID \
    --secret-permissions get list \
    --key-permissions get list

# placeholder setup needed if AZ CLI not used
az keyvault secret set --vault-name $AKV_NAME -n $PLACEHOLDER_SECRET_NAME --value "placeholder"  --output none

# Upload the root key and chain to the Key Vault
echo "Add the root and intermediate CA to Key Vault"
az keyvault secret set  --name "$rootCaKvSecretsNamePreFix-key-primary" --vault-name $AKV_NAME --file $rootKeyFileName  --content-type application/x-pem-file  --output none
az keyvault secret set  --name "$rootCaKvSecretsNamePreFix-cert-primary" --vault-name $AKV_NAME --file $rootCertFileName --content-type application/x-pem-file --output none
# for the secondary placeholder, copy in the primary root cert
az keyvault secret set  --name "$rootCaKvSecretsNamePreFix-cert-secondary" --vault-name $AKV_NAME --file $rootCertFileName --content-type application/x-pem-file --output none
# Upload intermediate key, cert and chain to Key Vault
az keyvault secret set  --name "$intermediateCaKvSecretsNamePreFix-key" --vault-name $AKV_NAME --file $intermediateKeyFileName  --content-type application/x-pem-file --output none
az keyvault secret set  --name "$intermediateCaKvSecretsNamePreFix-cert" --vault-name $AKV_NAME --file $intermediateCertFileName --content-type application/x-pem-file --output none
az keyvault secret set  --name "$intermediateCaKvSecretsNamePreFix-cert-chain" --vault-name $AKV_NAME --file $rootIntermediateCertChainFileName --content-type application/x-pem-file --output none

# Install CSI driver extension, ns, secrets and configmaps manually
echo "Adding the AKV Provider CSI Driver"
az k8s-extension create --cluster-name $CLUSTER_NAME --resource-group $RESOURCE_GROUP \
--cluster-type connectedClusters \
--extension-type Microsoft.AzureKeyVaultSecretsProvider \
--name $AKV_SECRET_PROVIDER_NAME \
--configuration-settings secrets-store-csi-driver.enableSecretRotation=true secrets-store-csi-driver.rotationPollInterval=$AKV_PROVIDER_POLLING_INTERVAL secrets-store-csi-driver.syncSecret.enabled=true

echo "Check if AKV extension is installed"
kubectl get pods -n kube-system

echo "Creating the '$DEFAULT_NAMESPACE' namespace"
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $DEFAULT_NAMESPACE
  labels:
    trust: enabled
EOF

echo "Adding AKV SP secret 'aio-akv-sp' in the namespace"
kubectl create secret generic aio-akv-sp --from-literal clientid="$AKV_SP_CLIENT_ID" --from-literal clientsecret="$AKV_SP_CLIENT_SECRET" --namespace $DEFAULT_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
kubectl label secret aio-akv-sp secrets-store.csi.k8s.io/used=true --namespace $DEFAULT_NAMESPACE

##############################################################################
# The below command will create the four required SecretProviderClasses into #
# the cluster, referencing the Placeholder Secret from AKV.                  #
#                                                                            #
#    !!! DO NOT CHANGE THE NAMES OF ANY OF THE SECRETPROVIDERCLASSES !!!     #
#                                                                            #
##############################################################################
echo "Creating Azure IoT Operations required SecretProviderClass resources"
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

# Install trust manager
echo "Installing trust manager"
helm repo add jetstack https://charts.jetstack.io --force-update
helm upgrade -i -n $DEFAULT_NAMESPACE cert-manager jetstack/cert-manager --set installCRDs=true --wait
helm upgrade -i -n $DEFAULT_NAMESPACE trust-manager jetstack/trust-manager --set-string app.trust.namespace=$DEFAULT_NAMESPACE  --wait

# Create a secret provider class for the intermediate cert
echo "Creating SecretProviderClass for Intermediate CA and Root CA trust"
kubectl apply -f - <<EOF
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: aio-secret-provider
  namespace: $DEFAULT_NAMESPACE
spec:
  provider: azure
  parameters:
    usePodIdentity: "false"
    keyvaultName: $AKV_NAME
    tenantId: $TENANT_ID
    objects: |
      array:
        - |
          objectName: $intermediateCaKvSecretsNamePreFix-cert-chain
          objectType: secret
        - |
          objectName: $intermediateCaKvSecretsNamePreFix-key
          objectType: secret
        - |
          objectName: $rootCaKvSecretsNamePreFix-cert-primary
          objectType: secret
        - |
          objectName: $rootCaKvSecretsNamePreFix-cert-secondary
          objectType: secret
  secretObjects: # [OPTIONAL] SecretObject defines the desired state of synced K8s secret objects
    - secretName: $PRIMARY_CA_KEY_PAIR_SECRET_NAME # name of the Kubernetes Secret object
      type: kubernetes.io/tls
      data:
        - objectName: $intermediateCaKvSecretsNamePreFix-cert-chain # data field to populate
          key: tls.crt
        - objectName: $intermediateCaKvSecretsNamePreFix-key # data field to populate
          key: tls.key
    - secretName: aio-ca-tls-primary-trust-bundle-test-only # name of the Kubernetes Secret object
      type: Opaque
      data:
        - objectName: $rootCaKvSecretsNamePreFix-cert-primary 
          key: $AIO_TRUST_CONFIG_MAP_KEY
    - secretName: aio-ca-tls-secondary-trust-bundle-test-only # name of the Kubernetes Secret object
      type: Opaque
      data:
        - objectName: $rootCaKvSecretsNamePreFix-cert-secondary
          key: $AIO_TRUST_CONFIG_MAP_KEY
EOF

echo "Deploying a dummy Pod to mount and sync secrets"
kubectl apply -f - <<EOF
kind: Deployment
apiVersion: apps/v1
metadata:
  name: aio-secrets-store-mount
  namespace: $DEFAULT_NAMESPACE
  labels:
    app: busybox
spec:
  replicas: 1
  selector:
    matchLabels:
      app: busybox
  template:
    metadata:
      labels:
        app: busybox
    spec:
      containers:
        - name: busybox
          image: k8s.gcr.io/e2e-test-images/busybox:1.29
          command:
            - "/bin/sleep"
            - "10000"
          volumeMounts:
            - name: secrets-store-inline
              mountPath: "/mnt/secrets-store"
              readOnly: true
          resources:
            requests:
              memory: "10Mi"
              cpu: "5m"
            limits:
              memory: "10Mi"
              cpu: "5m"
      volumes:
        - name: secrets-store-inline
          csi:
            driver: secrets-store.csi.k8s.io
            readOnly: true
            volumeAttributes:
              secretProviderClass: aio-secret-provider
            nodePublishSecretRef:
              name: aio-akv-sp
EOF

echo "Checking secret $PRIMARY_CA_KEY_PAIR_SECRET_NAME has been created"
# wait for creating of secret, check every 2 seconds
while [ "$(kubectl get secret -n $DEFAULT_NAMESPACE $PRIMARY_CA_KEY_PAIR_SECRET_NAME -o jsonpath='{.type}')" != "kubernetes.io/tls" ]; do
    echo "Waiting for secret to be created"
    sleep 2
done

kubectl get secret -n $DEFAULT_NAMESPACE $PRIMARY_CA_KEY_PAIR_SECRET_NAME

echo "Checking secret aio-ca-tls-primary-trust-bundle-test-only has been created"
kubectl get secret -n $DEFAULT_NAMESPACE aio-ca-tls-primary-trust-bundle-test-only

echo "Creating Bundle CR to be used by trust manager - pointing to the primary and secondary placeholder trust bundles"
kubectl apply -f - <<EOF
apiVersion: trust.cert-manager.io/v1alpha1
kind: Bundle
metadata:
  name: $AIO_TRUST_CONFIG_MAP
  namespace: $DEFAULT_NAMESPACE
spec:
  sources:
  - useDefaultCAs: false
  - secret:
      name: aio-ca-tls-primary-trust-bundle-test-only
      key: "$AIO_TRUST_CONFIG_MAP_KEY"
  target:
    configMap:
      key: "$AIO_TRUST_CONFIG_MAP_KEY"
    namespaceSelector:
      matchLabels:
        trust: enabled
EOF

echo "Checking azure-iot-operations namespace has configmaps"
kubectl get configmap -n $DEFAULT_NAMESPACE

# Create a workload namespace and validate the trust bundle is automatically created
echo "Creating the '$WORKLOAD_NAMESPACE' namespace"
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  labels:
    trust: enabled
  name: $WORKLOAD_NAMESPACE
EOF

echo "Checking $WORKLOAD_NAMESPACE namespace has trust bundle configmap '$AIO_TRUST_CONFIG_MAP' created"
kubectl get configmap -n $WORKLOAD_NAMESPACE

echo "Finished initialization of cluster"
#! /bin/bash

set -e


# ================================================================== #
# USE THIS SAMPLE IN CONJUNCTION WITH:
#  - 2-c-aio-init-intermediate.sh which using trust-manager
#  - 3-c-aio-deploy-intermediate.sh which deploys AIO extensions, Broker, skipping OPC UA due to temporary bug
#  - 4-c-aio-cert-intermediate-secondary.sh which creates a secondary Intermediate CA cert and key, signed by the Root CA primary
# 
# The intention of this demo is to show Root + Intermediate CA rollover
# On Disk:
# - creates a secondary root CA cert and key
# - creates a secondary Intermediate CA cert and key, signed by the Root CA secondary
# On Azure:
# - updates the Key vault secrets for the Root CA, chain and key - the old version is still in Key VaultR
# - updates the Key vault secrets for the Intermediate CA, chain and key - the old version is still in Key Vault
# On the cluster:
#  - updates the Trust Bundle ConfigMap with old and new roots (primary and secondary)
#  - checks that the Intermediate CA secret has been synced from Key Vault to the cluster
#  - calls cmctl CLI to renew the TLS certs using the new secret
#  - calls mosquitt_pub to the broker to verify the new cert using the new Root Secondary CA for trust
# ================================================================== #

# check if the required environment variables are set
if [ -z "$DEFAULT_NAMESPACE" ]; then
    echo "DEFAULT_NAMESPACE is not set"
    exit 1
fi
if [ -z "$WORKLOAD_NAMESPACE" ]; then
    echo "WORKLOAD_NAMESPACE is not set"
    exit 1
fi

# Variables
scriptPath=$(dirname $0)
randomValue=$RANDOM
# Cert file names
intermediateCertFileName="./temp/certs/ca-$randomValue-intermediate.crt"
intermediateKeyFileName="./temp/certs/ca-$randomValue-intermediate.key"
rootCertFileName="./temp/certs/ca-secondary.crt"
rootKeyFileName="./temp/certs/ca-secondary-cert.key"
rootIntermediateCertChainFileName="./temp/certs/intermediate-$randomValue-chain.crt"

# Key Vault secret names
rootCaKvSecretsNamePreFix="aio-root-ca"
intermediateCaKvSecretsNamePreFix="aio-intermediate-ca"


# Create secondary self-signed root cert authority
echo "Creating secondary root CA cert"
step certificate create --profile root-ca "AIO Root CA Secondary - Dev Only" $rootCertFileName $rootKeyFileName \
  --no-password --insecure --not-after 8760h # 365 days

echo "Creating rotation Intermediate CA with random name $randomValue"
# Create intermedia CA cert
step certificate create "AIO Intermediate CA $randomValue - Dev Only"  $intermediateCertFileName $intermediateKeyFileName \
        --profile intermediate-ca --ca $rootCertFileName --ca-key $rootKeyFileName \
        --no-password --insecure --not-after 2184h  # 91 days, renew every 3 months

# Chain the intermediate and root certs together and save to file on disk
cat $intermediateCertFileName $rootCertFileName > $rootIntermediateCertChainFileName

# Verify the certs
echo "Verifying the certs"
openssl verify -CAfile $rootCertFileName $rootIntermediateCertChainFileName

echo "Update key vault with new root and intermediate CA certs"
# Upload the root key and chain to the Key Vault
echo "Add the root and intermediate CA to Key Vault"
az keyvault secret set  --name "$rootCaKvSecretsNamePreFix-key" --vault-name $AKV_NAME --file $rootKeyFileName  --content-type application/x-pem-file  --output none
az keyvault secret set  --name "$rootCaKvSecretsNamePreFix-cert" --vault-name $AKV_NAME --file $rootCertFileName --content-type application/x-pem-file --output none
# Upload intermediate key, cert and chain to Key Vault
az keyvault secret set  --name "$intermediateCaKvSecretsNamePreFix-key" --vault-name $AKV_NAME --file $intermediateKeyFileName  --content-type application/x-pem-file --output none
az keyvault secret set  --name "$intermediateCaKvSecretsNamePreFix-cert" --vault-name $AKV_NAME --file $intermediateCertFileName --content-type application/x-pem-file --output none
az keyvault secret set  --name "$intermediateCaKvSecretsNamePreFix-cert-chain" --vault-name $AKV_NAME --file $rootIntermediateCertChainFileName --content-type application/x-pem-file --output none

# Update the trust bundle ConfigMap with both primary and secondary roots
# TLS configmap for trust bundle
echo "Creating secondary trust bundle ConfigMap to be used by trust manager"
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: aio-ca-tls-secondary-trust-bundle-test-only
  namespace: $DEFAULT_NAMESPACE
data:
  $AIO_TRUST_CONFIG_MAP_KEY: |
$(cat $rootCertFileName | sed 's/^/      /')
EOF

echo "Updating Bundle CR to be used by trust manager"
kubectl apply -f - <<EOF
apiVersion: trust.cert-manager.io/v1alpha1
kind: Bundle
metadata:
  name: $AIO_TRUST_CONFIG_MAP
  namespace: $DEFAULT_NAMESPACE
spec:
  sources:
  - useDefaultCAs: false
  - configMap:
      name: aio-ca-tls-primary-trust-bundle-test-only
      key: "$AIO_TRUST_CONFIG_MAP_KEY"
  - configMap:
      name: aio-ca-tls-secondary-trust-bundle-test-only
      key: "$AIO_TRUST_CONFIG_MAP_KEY"
  target:
    configMap:
      key: "$AIO_TRUST_CONFIG_MAP_KEY"
    namespaceSelector:
      matchLabels:
        trust: enabled
EOF

echo "Waiting 10 seconds for Trust Manager to sync the new trust bundle"
sleep 10

# Show current secret public cert part
echo "Get current public cert in the secret in the cluster"
kubectl get secret $PRIMARY_CA_KEY_PAIR_SECRET_NAME -n $DEFAULT_NAMESPACE -o jsonpath='{.data.tls\.crt}' | base64 --decode
echo "Please wait... 3 minutes for Key Vault secrets syncing to cluster and finish mounting flow"
counter=0
for i in {1..36}; do 
  echo -n "."
  sleep 5
  if (( i % 12 == 0 )); then
    echo " $((i*5)) seconds passed"
  fi
done

echo "Checking the contents of the tls.crt key in the secret"
newCert=$(kubectl get secret $PRIMARY_CA_KEY_PAIR_SECRET_NAME -n $DEFAULT_NAMESPACE -o jsonpath='{.data.tls\.crt}' | base64 --decode)
# Compare the newCert with the file on disk $intermediateChainFileName
if [ "$newCert" != "$(cat $rootIntermediateCertChainFileName)" ]; then
    echo "The new cert is not the same as the one on disk, waiting another 30 seconds"
    # wait another 30 seconds
    for i in {1..6}; do echo -n "."; sleep 5; done
fi

# Check the contents of the tls.crt key in the secret
echo "Getting public cert in the secret in the cluster - it should be the new one"
kubectl get secret $PRIMARY_CA_KEY_PAIR_SECRET_NAME -n $DEFAULT_NAMESPACE -o jsonpath='{.data.tls\.crt}' | base64 --decode 

# Use cmctl CLI to renew the certs using the secondary Intermedicate CA, which has been updated in the same secret
cmctl renew --namespace=azure-iot-operations --all
sleep 5 # wait for the new cert to be issued
# Get all events that have to do with certificate issuing
kubectl get events -n $DEFAULT_NAMESPACE | grep -E 'issu(er|ed|ing)'

# Checking the cert for MQ
echo "Using openssl to show rotated Intermediate $intermediateCertFileName and new root secondary CA for trust $rootCertFileName"
openssl s_client -connect localhost:8883 -showcerts -CAfile $rootCertFileName </dev/null

echo "Publishing a new MQTT message to the broker with new root secondary CA for trust, should be successful"
mosquitto_pub -h localhost -p 8883 -m "hello-$randomValue" -t "testcerts" -d --cafile $rootCertFileName

echo "Finished rollover to secondary Root CA, new trust bundle and rotated Intermediate CA key pair"

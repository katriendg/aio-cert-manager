#! /bin/bash

set -e


# ================================================================== #
# USE THIS SAMPLE IN CONJUNCTION WITH:
#  - ./deploy/kv-intermediate/2-c-aio-init.sh which using trust-manager
#  - ./deploy/kv-intermediate/3-c-aio-deploy.sh which deploys AIO extensions, Broker, skipping OPC UA due to temporary bug
#  - ./deploy/kv-intermediate/4-c-aio-cert-secondary.sh which creates a secondary Intermediate CA cert and key, signed by the Root CA primary
# 
# The intention of this demo is to show Root + Intermediate CA rollover
# On Disk:
# - creates a secondary root CA cert and key
# - creates a secondary Intermediate CA cert and key, signed by the Root CA secondary
# On Azure:
# - updserts the Key vault secrets for the Secondary Root CA, chain and key
# - updates the Key vault secrets for the Intermediate CA, chain and key - the old version is still in Key Vault
# On the cluster:
#  - updates the Trust Bundle ConfigMap with old and new roots (primary and secondary)
#  - checks that the Intermediate CA secret has been synced from Key Vault to the cluster
#  - calls cmctl CLI to renew the TLS certs using the new secret
#  - calls mosquitto_pub to the broker to verify the new cert using the new Root Secondary CA for trust
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
scriptPath=$(dirname $(dirname $0))
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

echo "Update key vault with secondary root and intermediate CA certs"
# Upload the root key and chain to the Key Vault
echo "Add the root and intermediate CA to Key Vault"
az keyvault secret set  --name "$rootCaKvSecretsNamePreFix-key-secondary" --vault-name $AKV_NAME --file $rootKeyFileName  --content-type application/x-pem-file  --output none
az keyvault secret set  --name "$rootCaKvSecretsNamePreFix-cert-secondary" --vault-name $AKV_NAME --file $rootCertFileName --content-type application/x-pem-file --output none
# Upload intermediate key, cert and chain to Key Vault
az keyvault secret set  --name "$intermediateCaKvSecretsNamePreFix-key" --vault-name $AKV_NAME --file $intermediateKeyFileName  --content-type application/x-pem-file --output none
az keyvault secret set  --name "$intermediateCaKvSecretsNamePreFix-cert" --vault-name $AKV_NAME --file $intermediateCertFileName --content-type application/x-pem-file --output none
az keyvault secret set  --name "$intermediateCaKvSecretsNamePreFix-cert-chain" --vault-name $AKV_NAME --file $rootIntermediateCertChainFileName --content-type application/x-pem-file --output none

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
  - secret:
      name: aio-ca-tls-secondary-trust-bundle-test-only
      key: "$AIO_TRUST_CONFIG_MAP_KEY"
  target:
    configMap:
      key: "$AIO_TRUST_CONFIG_MAP_KEY"
    namespaceSelector:
      matchLabels:
        trust: enabled
EOF

# Show current secret public cert part
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

# Check that Bundle has triggered ConfigMap update
echo "Checking the status of the Bundle - lastTransitionTime should be just minute(s) ago"
kubectl get Bundle $AIO_TRUST_CONFIG_MAP -n $DEFAULT_NAMESPACE -o json | jq '.status'

# Use cmctl CLI to renew the certs using the secondary Intermedicate CA, which has been updated in the same secret
cmctl renew --namespace=azure-iot-operations --all
sleep 5 # wait for the new cert to be issued
# Get all events that have to do with certificate issuing
kubectl get events -n $DEFAULT_NAMESPACE | grep -E 'issu(er|ed|ing)'

echo "Publishing a new MQTT message to the broker with new root secondary CA for trust, should be successful"
mosquitto_pub -h localhost -p 8883 -m "hello-$randomValue" -t "testcerts" -d --cafile $rootCertFileName

# For OPC Supervisor, restart the pod to pick up the new configmap, this does not happen automatically
echo "Restarting OPC Supervisor to pick up the new configmap trust bundle"
kubectl rollout restart deployment/aio-opc-supervisor -n $DEFAULT_NAMESPACE

echo "Finished rollover to secondary Root CA, new trust bundle and rotated Intermediate CA key pair"

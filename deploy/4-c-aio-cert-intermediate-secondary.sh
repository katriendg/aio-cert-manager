#! /bin/bash

set -e


# ================================================================== #
# USE THIS SAMPLE IN CONJUNCTION WITH:
#  - 2-c-aio-init-intermediate.sh which using trust-manager
#  - 3-c-aio-deploy-intermediate.sh which deploys AIO extensions, Broker, skipping OPC UA due to temporary bug
# 
# The intention of this demo is to show Intermediate CA rollover, while the Root CA trust bundle stays valid
# On Disk:
# - creates a secondary Intermediate CA cert and key, signed by the Root CA primary
# On Azure:
# - updates the Key vault secrets for the Intermediate CA, chain and key - the old version is still in Key Vault
# On the cluster:
#  - checks that the secret has been synced from Key Vault to the cluster - restarting the Dummy pod does this
#  - calls cmctl CLI to renew the TLS certs using the new secret
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
rootCertFileName="./temp/certs/ca-primary.crt"
rootKeyFileName="./temp/certs/ca-primary-cert.key"
rootIntermediateCertChainFileName="./temp/certs/intermediate-$randomValue-chain.crt"

# Key Vault secret names
rootCaKvSecretsNamePreFix="aio-root-ca"
intermediateCaKvSecretsNamePreFix="aio-intermediate-ca"

# Get the Root CA cert from Key Vault to disk - DEV ONLY - this should not be done for production systems
# Skipping this here as we are running this locally from temp folder
# az keyvault secret download --name "$rootCaKvSecretsNamePreFix-cert" --vault-name $AKV_NAME --file $rootCertFileName
# az keyvault secret download --name "$rootCaKvSecretsNamePreFix-key" --vault-name $AKV_NAME --file $rootKeyFileName

# Create secondary self-signed intermediate CA cert
echo "Creating secondary Intermediate CA"
# Create intermedia CA cert
step certificate create "AIO Intermediate CA $randomValue - Dev Only"  $intermediateCertFileName $intermediateKeyFileName \
        --profile intermediate-ca --ca $rootCertFileName --ca-key $rootKeyFileName \
        --no-password --insecure --not-after 2184h  # 91 days

# Chain the intermediate and root certs together and save to file on disk
cat $intermediateCertFileName $rootCertFileName > $rootIntermediateCertChainFileName

# Verify the certs
echo "Verifying the certs"
openssl verify -CAfile $rootCertFileName $rootIntermediateCertChainFileName

echo "Update key vault with new intermediate CA certs"
# Upload intermediate key, cert and chain to Key Vault
az keyvault secret set  --name "$intermediateCaKvSecretsNamePreFix-key" --vault-name $AKV_NAME --file $intermediateKeyFileName  --content-type application/x-pem-file --output none
az keyvault secret set  --name "$intermediateCaKvSecretsNamePreFix-cert" --vault-name $AKV_NAME --file $intermediateCertFileName --content-type application/x-pem-file --output none
az keyvault secret set  --name "$intermediateCaKvSecretsNamePreFix-cert-chain" --vault-name $AKV_NAME --file $rootIntermediateCertChainFileName --content-type application/x-pem-file --output none

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
echo "Using openssl to show the cert for the MQ broker - validate the chain reflects the secondary intermediate CA"
openssl s_client -connect localhost:8883 -showcerts -CAfile $rootCertFileName </dev/null

# Trust bundle has not changed, so publishing an MQTT message to the broker should be successful
echo "Publishing a new MQTT message to the broker still using the same root bundle, should be successful"
mosquitto_pub -h localhost -p 8883 -m "hello-$randomValue" -t "testcerts" -d --cafile $rootCertFileName

echo "Finished rollover to secondary Intermediate CA key pair and kept the Root CA trust bundle the same"

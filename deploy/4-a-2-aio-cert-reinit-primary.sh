#! /bin/bash

set -e

# Variables
scriptPath=$(dirname $0)

# Checking trust-manager generated bundle before changes:
echo "--------Trust Bundle before changes:"
kubectl get cm $AIO_TRUST_CONFIG_MAP -n $DEFAULT_NAMESPACE -o yaml

# Create another self-signed root cert authority (primary2)
echo "Creating primary (2) root CA certs"
>./temp/certs/ca-primary.conf cat <<EOF
[ req ]
distinguished_name = req_distinguished_name
prompt = no
x509_extensions = v3_ca

[ req_distinguished_name ]
CN=Azure IoT Operations Demo primary Root CA - Dev Only

[ v3_ca ]
basicConstraints = critical, CA:TRUE
keyUsage = keyCertSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
EOF
openssl ecparam -name prime256v1 -genkey -noout -out ./temp/certs/ca-primary-cert-key.pem
openssl req -new -x509 -key ./temp/certs/ca-primary-cert-key.pem -days 30 -config ./temp/certs/ca-primary.conf -out ./temp/certs/ca-primary-cert.pem
rm ./temp/certs/ca-primary.conf

# TLS secret creation - primary2
if kubectl get secret $PRIMARY_CA_KEY_PAIR_SECRET_NAME -n $DEFAULT_NAMESPACE &> /dev/null; then
	echo "TLS Secret $PRIMARY_CA_KEY_PAIR_SECRET_NAME already exists - deleting"
  kubectl delete secret $PRIMARY_CA_KEY_PAIR_SECRET_NAME -n $DEFAULT_NAMESPACE
fi

kubectl create secret tls $PRIMARY_CA_KEY_PAIR_SECRET_NAME --cert=./temp/certs/ca-primary-cert.pem --key=./temp/certs/ca-primary-cert-key.pem --namespace $DEFAULT_NAMESPACE	

# TLS configmap as source for trust bundle section - primary2
if kubectl get cm aio-ca-tls-primary-trust-bundle-test-only -n $DEFAULT_NAMESPACE &> /dev/null; then
	echo "Certificate manager aio-ca-tls-primary-trust-bundle-test-only already exists, deleting"
  kubectl delete cm aio-ca-tls-primary-trust-bundle-test-only -n $DEFAULT_NAMESPACE
fi

kubectl create cm aio-ca-tls-primary-trust-bundle-test-only --from-file=ca.crt=./temp/certs/ca-primary-cert.pem --namespace $DEFAULT_NAMESPACE

echo "--------Trust Bundle after configmap changes with primary2 cert chain:"
kubectl describe cm $AIO_TRUST_CONFIG_MAP -n $DEFAULT_NAMESPACE

# Update the Trust Bundle to contain the old and the new cert chain during the rotation
# Skipping as the trust bundle should pick up the updated cm 'aio-ca-tls-primary-trust-bundle-test-only' automatically

# Reconfigure the primary Issuer to contain the new root CA cert secret reference
echo "Updating MQ BrokerListener to point to primary Issuer to use new root CA cert secret reference"
# kubectl apply -f $scriptPath/yaml/cert-issuer-primary.yaml
kubectl apply -f $scriptPath/yaml/mq-broker-listener-primary.yaml

# Wait a few seconds, connect locally to the broker and check the new cert is used
sleep 20
echo "Publishing a new MQTT message to the broker using primary 2 CA bundle, should be successful"
mosquitto_pub -h localhost -p 8883 -m "hello-loc primary 2" -t "testcerts" -d --cafile ./temp/certs/ca-primary-cert.pem

# Restart OPC Supervisor, restart the pod to pick up the new configmap
kubectl rollout restart deployment/aio-opc-supervisor -n $DEFAULT_NAMESPACE

echo "--------Trust Bundle after configmap changes:"
kubectl get cm $AIO_TRUST_CONFIG_MAP -n $DEFAULT_NAMESPACE -o yaml

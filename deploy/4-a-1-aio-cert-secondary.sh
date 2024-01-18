#! /bin/bash

set -e

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

# TLS secret creation - secondary
if kubectl get secret $SECONDARY_CA_KEY_PAIR_SECRET_NAME -n $DEFAULT_NAMESPACE &> /dev/null; then
	echo "TLS Secret $SECONDARY_CA_KEY_PAIR_SECRET_NAME already exists, deleting before recreating"
  kubectl delete secret $SECONDARY_CA_KEY_PAIR_SECRET_NAME -n $DEFAULT_NAMESPACE
fi

kubectl create secret tls $SECONDARY_CA_KEY_PAIR_SECRET_NAME --cert=./temp/certs/ca-secondary-cert.pem --key=./temp/certs/ca-secondary-cert-key.pem --namespace $DEFAULT_NAMESPACE	

# TLS configmap as source for trust bundle section - secondary
if kubectl get cm aio-ca-tls-secondary-trust-bundle-test-only -n $DEFAULT_NAMESPACE &> /dev/null; then
	echo "Certificate manager aio-ca-tls-secondary-trust-bundle-test-only already exists, deleting before recreating"
  kubectl delete cm aio-ca-tls-secondary-trust-bundle-test-only -n $DEFAULT_NAMESPACE
fi

kubectl create cm aio-ca-tls-secondary-trust-bundle-test-only --from-file=ca.crt=./temp/certs/ca-secondary-cert.pem --namespace $DEFAULT_NAMESPACE

# Update the Trust Bundle to contain the old and the new cert chain during the rotation
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
      name: "aio-ca-tls-primary-trust-bundle-test-only"
      key: "ca.crt"
  - configMap:
      name: "aio-ca-tls-secondary-trust-bundle-test-only"
      key: "ca.crt"
  target:
    configMap:
      key: "$AIO_TRUST_CONFIG_MAP_KEY"
    namespaceSelector:
      matchLabels:
        trust: enabled
EOF

# Wait a few seconds for the pods to pick up the new configmap, and restart those that will not automatically do so
sleep 10

# Update the client pods to pick the new configmap before the rotation (currently only OPC Supervisor)
# Delay for the sync of the new configmap to the pods depends on configuration of kubelet and cache propagation delay
#  https://kubernetes.io/docs/concepts/configuration/configmap/#mounted-configmaps-are-updated-automatically
# For OPC Supervisor, restart the pod to pick up the new configmap, this does not happen automatically
kubectl rollout restart deployment/aio-opc-supervisor -n $DEFAULT_NAMESPACE
# in future for other clients such as Data processor - TODO
# Note: MQTT Mosquitto client pod does pick up new configmap with ca.crt trust bundle

# Create new Issuer to contain the secondary root CA cert secret reference
echo "Updating MQ BrokerListener and issuer to use new root CA cert secret reference"
# Workaround ------
# Issuer does not seem to detect CA secret content change to re-issue cert, so creating a new one
# BrokerListener update to refer to new issuer resource, this ensures new key pair is used and new cert issuance triggered
kubectl apply -f $scriptPath/yaml/cert-issuer-secondary.yaml
kubectl apply -f $scriptPath/yaml/mq-broker-listener-secondary.yaml
# -----------------

# Wait a few seconds, connect locally to the broker and check the new cert is used
sleep 20
echo "Publishing a new MQTT message to the broker using secondary CA bundle, should be successful"
mosquitto_pub -h localhost -p 8883 -m "hello-loc-secondary" -t "testcerts" -d --cafile ./temp/certs/ca-secondary-cert.pem

echo "--------Trust Bundle after configmap changes, waited 10 seconds:"
kubectl get cm $AIO_TRUST_CONFIG_MAP -n $DEFAULT_NAMESPACE -o yaml


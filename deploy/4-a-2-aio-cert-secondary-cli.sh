#! /bin/bash

set -e

# This is another approach to renewing the certs, ensuring re-issuance by using cmctl CLI
# https://cert-manager.io/docs/reference/cmctl/#renew

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

# chain the two certs together for local testing
cat  ./temp/certs/ca-secondary-cert.pem ./temp/certs/ca-primary-cert.pem > ./temp/certs/ca-two-certs.pem
kubectl create cm opc-trust-bundle-lastfirst --from-file=ca.crt=./temp/certs/ca-two-certs.pem --namespace $DEFAULT_NAMESPACE

# Wait a few seconds for the pods to pick up the new configmap, and restart those that will not automatically do so
sleep 10

# TLS secret creation - secondary key pair as content
if kubectl get secret $PRIMARY_CA_KEY_PAIR_SECRET_NAME -n $DEFAULT_NAMESPACE &> /dev/null; then
	echo "TLS Secret $PRIMARY_CA_KEY_PAIR_SECRET_NAME already exists - deleting"
  kubectl delete secret $PRIMARY_CA_KEY_PAIR_SECRET_NAME -n $DEFAULT_NAMESPACE
fi

kubectl create secret tls $PRIMARY_CA_KEY_PAIR_SECRET_NAME --cert=./temp/certs/ca-secondary-cert.pem --key=./temp/certs/ca-secondary-cert-key.pem --namespace $DEFAULT_NAMESPACE	

# Use CLI to renew the certs using the same secret
cmctl renew --namespace=azure-iot-operations --all
sleep 10 # wait for the new secret to be created
kubectl get events | grep issu

# Update the client pods to pick the new configmap before the rotation (currently only OPC Supervisor)
# Delay for the sync of the new configmap to the pods depends on configuration of kubelet and cache propagation delay
#  https://kubernetes.io/docs/concepts/configuration/configmap/#mounted-configmaps-are-updated-automatically
# For OPC Supervisor, restart the pod to pick up the new configmap, this does not happen automatically
kubectl rollout restart deployment/aio-opc-supervisor -n $DEFAULT_NAMESPACE

# in future for other clients such as Data processor - TODO
# Note: MQTT Mosquitto client pod picks up new configmap with ca.crt trust bundle quite quickly

# connect locally to the broker and check the new cert is used
echo "Publishing a new MQTT message to the broker using secondary CA bundle, should be successful"
mosquitto_pub -h localhost -p 8883 -m "hello-loc-secondary" -t "testcerts" -d --cafile ./temp/certs/ca-two-certs.pem

echo "Finished rollover to secondary root CA key pair and trust bundle"
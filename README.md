# Azure IoT Operations (AIO) TLS Certificate Management Sample

This Azure IoT Operations example showcases strategies and methods for managing, renewing, and handling TLS certificates and trust bundles. The objective of this example is to explore and confirm ways to transition CA Certificates with minimal disruption to AIO services and client tasks.

For a review of concepts such as TLS, Certificates, CA, and Trust Bundles, refer to: [Certificates, Roots CAs, Intermediate CA, Leaf Certificates, Trust and TLS](./docs/certs-tls-bundles-doc.md).

> Please note, this repository is designed for educational purposes and does not constitute official advice.

## Deployment and Testing Flow

### Pre-requisites

* Visual Studio Code
* Dev Containers
* Azure subscription
* Docker runtime

### Initialization

Open this project in a Visual Studio Dev Container. K3D cluster and any documented client tools will be automatically installed and ready to use for testing out the samples in this project.

Prepare the following inputs to create environment variables in the next step:

* Ensure you are logged in to Azure and set your default subscription `az account set -s <yoursubscription>`
* Follow the official guidance to prepare a Service Principal with the correct configuration to use for the environment variables `AKV_SP_CLIENT_ID`, `AKV_SP_CLIENT_SECRET` and `AKV_SP_OBJECT_ID` following [Configure service principal for interacting with Azure Key Vault via Microsoft Entra ID](https://learn.microsoft.com/en-us/azure/iot-operations/deploy-iot-ops/howto-manage-secrets#configure-service-principal-for-interacting-with-azure-key-vault-via-microsoft-entra-id)
* `ARC_CUSTOMLOCATION_OID`: retrieve the unique Custom location Object ID for your tenant by running `az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv`
* `TENANT_ID`: your Microsoft Entra ID Tenant ID
* `LOCATION`: make sure you choose something from the supported list of regions as documented in [Deploy Azure IoT Operations, see Location table](https://learn.microsoft.com/en-us/azure/iot-operations/get-started/quickstart-deploy?tabs=codespaces#connect-a-kubernetes-cluster-to-azure-arc)
* Use your preferred Azure resource names where you can find the `...` in the variable contents

Create a file to load environment variables under `./temp/envvars.sh`, with the following contents:

```bash
# change the below set to match your environment
export RESOURCE_GROUP=rg-...
export CLUSTER_NAME=arck-...
export TENANT_ID="..."
export AKV_SP_CLIENT_ID="..."
export AKV_SP_CLIENT_SECRET="..."
export AKV_SP_OBJECT_ID="..." 
export LOCATION=...
export ARC_CUSTOMLOCATION_OID="..."
export AKV_NAME=akv-...
# Below should not be changed, referenced by ARM and YAML files
export DEFAULT_NAMESPACE=azure-iot-operations
export WORKLOAD_NAMESPACE=workload
export PRIMARY_CA_KEY_PAIR_SECRET_NAME=aio-ca-key-pair-test-only
export SECONDARY_CA_KEY_PAIR_SECRET_NAME=aio-ca-key-pair-secondary-test-only
export AIO_TRUST_CONFIG_MAP_KEY="ca.crt"
export AIO_TRUST_CONFIG_MAP=aio-ca-trust-bundle-test-only
```

Load the environment variables in your terminal by running

```bash
source ./temp/envvars.sh
```

## Repo Samples

This repo contains several experiments for CA root cert key pair renewal, one using `cmctl` command line to force re-issuance of the certs, using multiple `Issuer` resources and updating `BrokerListener` *Custom Resource*, and using just Root CA or extending to Intermediate CA usage. The experiments use *OpenSSL* and *step cli* to create self-signed CA certificates and keys.

### Sample with `cmctl` CLI to renew certs and manual updating of trust bundle

This is the simpler solution for ensuring rollover but it does require [`cmctl`](https://cert-manager.io/docs/reference/cmctl/) command line, which is pre-installed with the Dev Container. This command line tool could be part of an automation pipeline to execute the require certificate re-issuance.

The current sample installs Key Vault, Key Vault CSI Driver Arc extension, AIO Arc extension, MQ Arc extension, Issuer, Broker and BrokerListener CRs, and OPC UA Broker and Connector using Helm charts.

```bash
# ensure Environment Variables are set as described in Readme section Initialization

# initialize Arc
./deploy/1-arc-connect.sh

# initialize cert, AIO configmaps and secrets, key vault, CSI driver
./deploy/2-b-aio-init.sh

# install AIO (ARM template, Broker stuff via CRD and OPC UA via Helm)
./deploy/3-aio-deploy.sh 

# Check AIO is running, then rollover to secondary cert by running
./deploy/4-b-aio-cert-secondary-cli.sh 
```

The most relevant part of this flow to review is in the last script `4-b-aio-cert-secondary.sh` where a secondary CA root key pair is created, the ConfigMap with the trust bundle is updated to include primary AND secondary certs so clients can trust both old and new certs upfront (check this section in the official *cert-manager* documentation [cert-manager Integration: Intentionally Copying CA Certificates
](https://cert-manager.io/docs/trust/trust-manager/#cert-manager-integration-intentionally-copying-ca-certificates)). The script then updates the secret replacing the primary cert/key with the secondary. This does not automatically trigger cert re-issuance so this is then forced by using the `cmctl certificate renew` command line.

Because TLS clients such as OPC UA Supervisor don't automatically pick up the new trust bundle via ConfigMap mount, it is also necessary to restart the pods for some services.

### Sample with *trust-manager*  and manual rollover using new Issuer for BrokerListener

This sample uses *trust-manager* and uses a new `Issuer` to pick-up root cert changes. Take a moment to review the different steps taken by the scripts. For this sample use:

```bash
# ensure Environment Variables are set as described in Readme section Initialization

# initialize Arc
./deploy/1-arc-connect.sh

# initialize cert, AIO configmaps and secrets, key vault, CSI driver, install trust-manager and setup Bundle
./deploy/2-a-aio-init.sh

# install AIO (ARM template, Broker stuff via CRD and OPC UA via Helm)
./deploy/3-aio-deploy.sh 

# Check AIO is running, then rollover to secondary cert by running
# This uses trust manager and a new Issuer, updates BrokerListener
./deploy/4-a-1-aio-cert-secondary.sh

# Optionally using the same pattern, rollover to a new primary
./deploy/4-a-2-aio-cert-reinit-primary.sh 
```

This sample also has an option for renewing the certs using  `cmctl` CLI for *cert-manager* to re-issue the certificates and does not need to use a new `Issuer` or updates to `BrokerListener`. It can be run after `./deploy/3-aio-deploy.sh`.

```bash
# After running ./deploy/3-aio-deploy.sh and you want to renew certs using 'trust-manager' and cmctl CLI:
./deploy/4-a-2-aio-cert-secondary-cli.sh 
```

### Sample using Self-signed Root, Intermediate CA, Key Vault, *trust-manager* and `cmctl` for certificate renewal

In this example the aim is to walk through all the steps that are required to leverage a Root CA and an Intermediate CA, and roll these over. The intermediate CA is the one used by the cluster for issuing server certificates by `cert-manager`. Although the sample here is leveraging self-signed certificates, it shows a potential flow with certificates delivered by a PKI for production.

This sample can be used as a learning experiment to understand the concepts of Root and Intermediate CAs, leaf certificates, certificate chains, trust bundles and chain verification.
The Root CA is valid for 365 days, the Intermediate CA is valid for 91 days where we assume the Intermediate CA would need to be rolled over every 3 months. The rollover needs to happen before the 3 month period is reached.

For this sample use the following:

```bash
# ensure Environment Variables are set as described in Readme section Initialization

# initialize Arc
./deploy/1-arc-connect.sh

# initialize root/intermediate certs, upload to Key Vault, AIO configmaps and secrets, key vault, CSI driver, install trust-manager and setup Bundle
./deploy/kv-intermediate/2-aio-init.sh

# install AIO (ARM template, Broker stuff via CRD and OPC UA via Helm)
./deploy/kv-intermediate/3-aio-deploy.sh 
```

This section initializes the cluster with AIO, an Intermediate CA chain, a trust `Bundle` managed by *trust-manager* and a sample Mosquitto client Pod in the `workload` namespace. Please see the section [Testing with in-cluster Mosquitto client tools to validate trust chains](#testing-with-in-cluster-mosquitto-client-tools-to-validate-trust-chains) and play with the options.

The next phase would be to rollover the Intermediate CA and ensuring the server certificates are reissued. This is under the assumption that the Root CA is valid for a much longer time than the Intermediate CA. Because the Root CA is still valid, the ConfigMap with trust bundle used by the clients does not need updating. Also any client Pods will not need to pick up any new ConfigMap updates so no Pod restarts are needed.

```bash

# Rollover to secondary Intermediate CA by running 
./deploy/kv-intermediate/4-aio-cert-secondary.sh

```

You can again play with the Mosquitto Pod to verify the contents of the ConfigMap and the connection to the MQ broker.

The final phase is to rollover the Root CA to a secondary new self-signed cert. This also requires the Intermediate CA to be rolled over and be signed by the new secondary Root CA. The ConfigMap with the trust bundle should contain both the primary and secondary root CAs so that clients never lose the ability to validate the server chain which may change at any point. Only after this has been ensured can the Intermediate CA be rolled over and the new server certificate issued.

```bash
# After running ./deploy/4-c-aio-cert-intermediate-secondary you want to renew Root and Intermediate certs using 'trust-manager' and cmctl CLI:
./deploy/kv-intermediate/5-aio-cert-root-secondary.sh 
```

### Testing with in-cluster Mosquitto client tools to validate trust chains

All samples also deploy a Pod that contains Mosquitto client tools (`mosquitto_pub` and `mosquitto_sub`), which mounts the trust bundle as a ConfigMap and following Kubernetes' [ConfigMap auto-updates](https://kubernetes.io/docs/concepts/configuration/configmap/#mounted-configmaps-are-updated-automatically) this is a great example of having cert bundles synced automatically. Take a look at the deployment file [mosquitto_client.yaml](./deploy/yaml/mosquitto_client.yaml).

Some learnings:

* In the sample Pod it typically takes about 30 seconds to sync the ConfigMap mount contents. Note this is not deterministic as officially documented
* When the client has an open TLS connection like using `mosquitto_sub` that keeps the connection alive, the connection can stay valid for a while until new TLS handshake needs to be done. Only at this time is the trust bundle needed

Check there is a ConfigMap named `aio-ca-trust-bundle-test-only`.

```bash
kubectl get configmap -n $WORKLOAD_NAMESPACE
```

Describe the ConfigMap, if you followed one of the samples leveraging *trust-manager* you will see a label referring to this.

```bash
kubectl describe cm aio-ca-trust-bundle-test-only -n $WORKLOAD_NAMESPACE
```

Open interactive terminal into the Mosquitto Pod.

```bash
kubectl exec --stdin --tty mosquitto-client -n $WORKLOAD_NAMESPACE -- sh
```

Check the current contents of the mounted `ca.crt` file.

```bash
cat /var/run/certs/ca.crt
```

Publish a message to the MQ broker adding the `--cafile` parameter to point to the trust bundle that has been mounted.

```bash
mosquitto_pub -h aio-mq-dmqtt-frontend.azure-iot-operations.svc.cluster.local -p 8883 -t "testcerts" -m "hello world" -d --cafile /var/run/certs/ca.crt
```

At any time if you want to better understand which root cert has been used to issue the MQ server cert you can run the following, knowing that `localhost` port mapping is already setup in the Dev Container, and the DNS of the issued cert does contain `localhost` for local dev testing.

```bash
openssl s_client -showcerts -connect localhost:8883 </dev/null

# Notice the name of the cert and also cert verification issues

# ---
# SSL handshake has read 1516 bytes and written 407 bytes
# Verification error: self-signed certificate in certificate chain
# ---
# ...
# Verify return code: 19 (self-signed certificate in certificate chain)

```

To see SSL verification validation or errors, depending on which `-CAfile` you use with your request, you can use the following:

```bash
openssl s_client -showcerts -connect localhost:8883 -CAfile ./temp/certs/[yoursecondarycertname] </dev/null

# Review the SSL handshake:
# ---
# SSL handshake has read 1518 bytes and written 407 bytes
# Verification: OK
# ---
# ...
# Verify return code: 0 (ok)
```

Also take a moment to check the `Certificate`, its associated `Secret` and `CertificateRequest` resources and their events.

```bash
# Review all CertificateRequests
kubectl get CertificateRequest -n $DEFAULT_NAMESPACE

# Check the details of the request matching the aio-mq-frontend-server-8883-xxx
# You will see a field Status.ca which contains the base64 public CA cert - you can use this to validate which CA has been used. 
kubectl describe CertificateRequest aio-mq-frontend-server-8883-xxx -n $DEFAULT_NAMESPACE

# Review the Certificate that has been issued for the MQ front-end listener, it will show DNS, renewal timings, etc
kubectl describe Certificate aio-mq-frontend-server-8883 -n $DEFAULT_NAMESPACE

# The actual Certificate is stored in a secret named `aio-mq-frontend-server-8883`
kubectl get secret aio-mq-frontend-server-8883 -n $DEFAULT_NAMESPACE -o jsonpath='{.data.tls\.crt}' | base64 --decode

```

## TODOs

* Add a document about pros and cons around Intermediate CAs
* For the Intermediate CA Sample: document how the CA is preset in Key Vault and on SPC + Bundle as a duplicate of Primary until first rollover
* Document TLS Handshake

## Things to Understand

* How do trust bundles work, mounting them, using them in pods
* Certificate chains and TLS handshake
* How *cert-manager* `Issuer` work with `ca` spec with a secret, and when are certs re-issued. For example changes to the secret are not detected automatically for the cert to be re-issued. There is still an open GH issue on the topic: [https://github.com/cert-manager/cert-manager/issues/2478](https://github.com/cert-manager/cert-manager/issues/2478)
* Basics of using *trust-manager*  as an option for managing (public) trust
* How typically pods needs to restart to pick up the changes and re-initialize the connection to MQ Broker (TLS handshake needs to be re-initialized)
* Using `cmctl` CLI to manually trigger re-issuance of certs based on root key pair changes

## Resources

* [Manage TLS Certificates in a Cluster](https://kubernetes.io/docs/tasks/tls/managing-tls-in-a-cluster/)
* [cert-manager](https://cert-manager.io/docs/)
* [trust-manager](https://cert-manager.io/docs/trust/trust-manager/)
* [Managing public trust in kubernetes with trust-manager](https://cert-manager.io/docs/tutorials/getting-started-with-trust-manager/)

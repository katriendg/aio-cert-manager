# Azure IoT Operations (AIO) Certificate Management Sample

Azure IoT Operations sample that highlights mechanisms and patterns to take care of TLS cert management, renewal and trust bundles.

The aim of this sample is to research and validate means to rollover CA Certs with minimal impact on AIO services and client workloads.

## Deployment and Testing Flow

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
export AKV_NAME=...
# Below should not be changed, referenced by ARM and yaml files
export DEFAULT_NAMESPACE=azure-iot-operations
export WORKLOAD_NAMESPACE=workload
export PRIMARY_CA_KEY_PAIR_SECRET_NAME=aio-ca-key-pair-test-only
export SECONDARY_CA_KEY_PAIR_SECRET_NAME=aio-ca-key-pair-secondary-test-only
export AIO_TRUST_CONFIG_MAP_KEY="ca.crt"
export AIO_TRUST_CONFIG_MAP=aio-ca-trust-bundle-test-only
```

## Repo Samples

### Sample with `cmctl` CLI to renew certs and manual updating of trust bundle

This is the most simplified solution for ensuring rollover but it does require [`cmctl`](https://cert-manager.io/docs/reference/cmctl/) command line, which is pre-installed with the Dev Container.

The current sample installs Key Vault, KV CSI Driver Arc extension, AIO Arc extension, MQ Arc extension, Issuer, Broker and BrokerListener CRs, and OPC UA Broker and connector using Helm charts.

```bash
# ensure Environment Variables are set as described in Readme

# initialize Arc
./deploy/1-arc-connect.sh

# initialize cert, AIO configmaps and secrets, key vault, CSI driver
./deploy/2-b-aio-init.sh

# install AIO (ARM template, Broker stuff via CRD and OPC UA via Helm)
./deploy/3-aio-deploy.sh 

# Check AIO is running, then rollover to secondary cert by running
./deploy/4-b-aio-cert-secondary.sh 
```

The most relevant part of this flow to review is in the last script `4-b-aio-cert-secondary.sh` where a secondary CA root key pair is created, the ConfigMap with the trust bundle is updated to include primary AND secondary certs so clients can trust both old and new certs upfront. The script then updates the secret replacing the primary cert/key with the secondary. This does not automatically trigger cert re-issuance so this is then forced by using the `cmctl certificate renew` command line.

Because TLS clients such as OPC UA Supervisor don't automatically pick up the new trust bundle via ConfigMap mount, it is also necessary to restart the pods for some services.

### Sample with trust-manager and manual rollover using new Issuer for BrokerListener

This sample uses `trust-manager` and uses a new `Issuer` to pick-up root cert changes. Take a moment to review the different steps taken by the scripts. For this sample use:

```bash
# ensure Environment Variables are set as described in Readme

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

This sample also has an example of renewing the certs using the `cmctl` CLI for cert-manager to re-issue the certificates and does not need to use a new `Issuer` or update `BrokerListener`. It can be run after `./deploy/3-aio-deploy.sh`.

```bash
# After running ./deploy/3-aio-deploy.sh and you want to renew certs using 'trust-manager' and cmctl CLI:
./deploy/4-a-2-aio-cert-secondary-cli.sh 
```

### Testing with in-cluster Mosquitto client tools to validate trust chanins

Both samples also deploy a Pod that contains Mosquitto client tools (`mosquitto_pub` and `mosquitto_sub`), which mounts the trust bundle as a ConfigMap and following Kubernetes' [ConfigMap auto-updates](https://kubernetes.io/docs/concepts/configuration/configmap/#mounted-configmaps-are-updated-automatically) this is a great example of having cert bundles synced automatically. Take a look at the deployment file [mosquitto_client.yaml](./deploy/yaml/mosquitto_client.yaml).

Some learnings:

* In the sample Pod it typically takes about 30 seconds to sync the ConfigMap mount contents. Note this is not deterministic as officially documented
* When the client has an open TLS connection like using `mosquitto_sub` that keeps the connection alive, the connection can stay valid for a while until new TLS handshake needs to be done
* 

Test it out:

```bash
# Check that there is a ConfigMap ''
kubectl get configmap -n $WORKLOAD_NAMESPACE

kubectl describe cm aio-ca-trust-bundle-test-only -n $WORKLOAD_NAMESPACE

# Exec into the pod
kubectl exec --stdin --tty mosquitto-client -n workload -- sh

# Check the current contents of the mounted ca.crt file
cat /var/run/certs/ca.crt

# Send a message to the broker adding the --cafile that has been mounted
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
openssl s_client -showcerts -connect localhost:8883 -CAfile ./temp/certs/ca-secondary-cert.pem </dev/null

# Review the SSL handshake:
# ---
# SSL handshake has read 1518 bytes and written 407 bytes
# Verification: OK
# ---
# ...
# Verify return code: 0 (ok)
```



## Things to Understand

* How do trust bundles work and mounting them, using them in pods
* How cert-manager Issuer work with reference to ca spec with a secret, when are certs re-issued. For example changes to the secret are not detected automatically for the cert to be re-issued. There is still an open GH issue on the topic: [https://github.com/cert-manager/cert-manager/issues/2478](https://github.com/cert-manager/cert-manager/issues/2478)
* Basics of using trust-manager as an option for managing (public) trust
* How pods with ConfigMaps as mounted volumes do and don't sync, as well as sync delay with K8S
* How typically pods needs to restart to pick up the changes and re-initialize the connection to MQ Broker (TLS handshake needs to be re-initialized)
* Using `cmctl` CLI to manually trigger re-issuance of certs based on root key pair changes

## Resources

* [cert-manager](https://cert-manager.io/docs/)
* [trust-manager](https://cert-manager.io/docs/trust/trust-manager/)
* [Managing public trust in kubernetes with trust-manager](https://cert-manager.io/docs/tutorials/getting-started-with-trust-manager/)
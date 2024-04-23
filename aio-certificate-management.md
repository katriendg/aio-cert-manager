# AIO MQ Certificate management

## Context

AIO MQ uses certificates to enable TLS for endpoints like the IoT MQ Frontend. This certificate needs to be on the cluster prior to installing AIO MQ, otherwise the installation fails.

The goal of this document is to showcase different approaches to manage certificates for AIO MQ and their pros and cons.

## Options

### Single Root CA

With single Root CA approach a new Root CA is created for each cluster (either self signed or with a PKI infrastructure) and this Root CA is used for issuing server certificates by `cert-manager`. In order for the certificates issues by `cert-manager` to be trusted by clients a trust bundle needs to be created and signed by the Root CA and distributed to the clients.

This is the approach also used within the AIO quick starts, where a self signed Root CA and trust bundles are created with a script on the device the cluster is and applied to the cluster.

In the scenario that the Root CA needs to renewed, either because it has expired or because it is compromised, the cluster needs to be re-issued a new Root CA and all trust bundles need to be updated on all clients. To avoid downtime the client trust bundles need to be updated before the Root CA is updated on the cluster, as roll over to a new Root CA will not be instantaneous. This means, there will be a period of time that the clients need to trust both the old and the new Root CA.

The renewal needs to be a three step process:

1. Create a new Root CA and trust bundles
2. Update the trust bundles on all clients with the new trust bundles and the old trust bundles
3. Update the Root CA on the cluster with the new Root CA

### Root and Intermediate CA

With the Root and Intermediate CA approach a Root CA is created and an Intermediate CA is signed by the Root CA. An Intermediate CA is created for each cluster and this Intermediate CA is used for issuing server certificates by `cert-manager`. In order for the certificates issues by `cert-manager` to be trusted by clients a trust bundle needs to be created and signed by the Root CA and distributed to the clients.

In the event of a renewal of the Intermediate CA, the Intermediate CA can be rolled over without the need to update the trust bundles on the clients. This is because all the clients trust all certificated that have been singed by the top level CA.

In addition, the Root CA can be kept offline and only used to sign the Intermediate CA, which limits the exposure of the Root CA.

This approach also allows for a shorter validity period for the Intermediate CA, which can be rolled over more frequently than the Root CA.

However, in the event of a renewal of the Root CA the process is the same as with the single Root CA approach.

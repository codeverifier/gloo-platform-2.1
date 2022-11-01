#!/bin/bash

###################################################################
# Script Name   : vault-bootstrap-relay-pki-gen.sh
# Description   : Manage Gloo Mesh relay certificate generation with Vault
# Author        : Kasun Talwatta
# Email         : kasun.talwatta@solo.io
###################################################################

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

check_vault_status() {
    vault status &> /dev/null
    while [[ $? -ne 0 ]]; do sleep 5; vault status &> /dev/null; done
}

generate() {
    echo "------------------------------------------------------------"
    echo "Bootstrapping the relay PKI"
    echo "------------------------------------------------------------"
    echo ""

    kubectl --context ${MGMT_CONTEXT} create namespace gloo-mesh --dry-run=client -o yaml | kubectl --context ${MGMT_CONTEXT} apply -f -

    # Find the public IP for the vault service
    export VAULT_LB=$(kubectl --context ${MGMT_CONTEXT} get svc -n vault vault \
        -o jsonpath='{.status.loadBalancer.ingress[0].*}')
    export VAULT_ADDR="http://${VAULT_LB}:8200"
    export VAULT_TOKEN="root"

    if [[ -z "${VAULT_LB}" ]]; then
      echo "Unable to obtain the address for the Vault service"
      exit 1
    fi

    check_vault_status

    COMMON_NAME="gloo-mesh-mgmt-server"
    CERT_GEN_DIR=$DIR/../../_output/certs/relay
    mkdir -p $CERT_GEN_DIR

    # Generate offline root CA (10 year expiry)
    cfssl genkey \
      -initca $DIR/relay/root-template.json | cfssljson -bare $CERT_GEN_DIR/root-cert

    # Generate an intermediate CA
    vault secrets enable -path relay-pki-int pki

    vault write -field=csr \
      relay-pki-int/intermediate/generate/internal \
      common_name=${COMMON_NAME} \
      key_type=rsa \
      key_bits=4096 \
      max_path_length=1 \
      ttl="43800h" > $CERT_GEN_DIR/int-request.csr

    # Sign the CSR using the offline root
    cfssl sign \
      -ca $CERT_GEN_DIR/root-cert.pem \
      -ca-key $CERT_GEN_DIR/root-cert-key.pem \
      -config $DIR/relay/int-config.json \
      $CERT_GEN_DIR/int-request.csr | cfssljson -bare $CERT_GEN_DIR/int-ca

    # Set signed cert with the extracted blob
    vault write -format=json \
      relay-pki-int/intermediate/set-signed \
      certificate=@$CERT_GEN_DIR/int-ca.pem

    # Configure a role
    vault write \
      relay-pki-int/roles/gloo-mesh-mgmt-server \
      allow_any_name=true max_ttl="720h"

    rm -f $CERT_GEN_DIR/root-cert-key.pem

    echo ""
    echo "Configuring certificate manager to issue relay server certificate"
    kubectl --context ${MGMT_CONTEXT} create secret generic vault-token --from-literal=token=root -n gloo-mesh
        
    kubectl --context ${MGMT_CONTEXT} apply -f- <<EOF
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: vault-issuer
  namespace: gloo-mesh
spec:
  vault:
    path: relay-pki-int/sign/gloo-mesh-mgmt-server
    server: http://vault-internal.vault.svc:8200
    auth:
      tokenSecretRef:
        name: vault-token
        key: token
EOF

    sleep 15

    kubectl --context ${MGMT_CONTEXT} apply -f- <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: relay-server-tls
  namespace: gloo-mesh
spec:
  commonName: "${COMMON_NAME}"
  dnsNames:
    - "${COMMON_NAME}"
    - "${COMMON_NAME}.gloo-mesh"
    - "${COMMON_NAME}.gloo-mesh.svc"
    - "*.gloo-mesh"
  secretName: relay-server-tls-secret
  duration: 720h
  renewBefore: 700h
  privateKey:
    rotationPolicy: Always
    algorithm: RSA
    size: 2048
  usages:
    - digital signature
    - key encipherment
    - server auth
    - client auth
  issuerRef:
    name: vault-issuer
    kind: Issuer
    group: cert-manager.io
EOF

    sleep 15

    echo ""
    echo "Configuring certificate manager to issue the relay client certificate for West cluster"
    kubectl --context ${WEST_CONTEXT} create namespace gloo-mesh --dry-run=client -o yaml | kubectl --context ${WEST_CONTEXT} apply -f -
    kubectl --context ${WEST_CONTEXT} create secret generic vault-token --from-literal=token=root -n gloo-mesh

    kubectl --context ${WEST_CONTEXT} apply -f- <<EOF
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: vault-issuer
  namespace: gloo-mesh
spec:
  vault:
    path: relay-pki-int/sign/gloo-mesh-mgmt-server
    server: $VAULT_ADDR
    auth:
      tokenSecretRef:
        name: vault-token
        key: token
EOF

    sleep 15

    kubectl apply --context ${WEST_CONTEXT} -f- <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: relay-client-tls
  namespace: gloo-mesh
spec:
  commonName: "${COMMON_NAME}"
  dnsNames:
    - "$WEST_MESH_NAME"
  secretName: relay-client-tls-secret
  duration: 720h
  renewBefore: 700h
  privateKey:
    rotationPolicy: Always
    algorithm: RSA
    size: 2048
  issuerRef:
    name: vault-issuer
    kind: Issuer
    group: cert-manager.io
EOF

    echo ""
    echo "Configuring certificate manager to issue the relay client certificate for East cluster"
    kubectl --context ${EAST_CONTEXT} create namespace gloo-mesh --dry-run=client -o yaml | kubectl --context ${EAST_CONTEXT} apply -f -
    kubectl --context ${EAST_CONTEXT} create secret generic vault-token --from-literal=token=root -n gloo-mesh

    kubectl --context ${EAST_CONTEXT} apply -f- <<EOF
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: vault-issuer
  namespace: gloo-mesh
spec:
  vault:
    path: relay-pki-int/sign/gloo-mesh-mgmt-server
    server: $VAULT_ADDR
    auth:
      tokenSecretRef:
        name: vault-token
        key: token
EOF

    sleep 15

    kubectl --context ${EAST_CONTEXT} apply -f- <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: relay-client-tls
  namespace: gloo-mesh
spec:
  commonName: "${COMMON_NAME}"
  dnsNames:
    - "$EAST_MESH_NAME"
  secretName: relay-client-tls-secret
  duration: 720h
  renewBefore: 700h
  privateKey:
    rotationPolicy: Always
    algorithm: RSA
    size: 2048
  issuerRef:
    name: vault-issuer
    kind: Issuer
    group: cert-manager.io
EOF

}

delete() {
    echo "Cleaning up ..."

    kubectl --context ${MGMT_CONTEXT} delete secret vault-token -n gloo-mesh
    kubectl --context ${MGMT_CONTEXT} delete secret relay-server-tls-secret -n gloo-mesh
    kubectl --context ${MGMT_CONTEXT} delete issuer vault-issuer -n gloo-mesh
    kubectl --context ${MGMT_CONTEXT} delete certificate relay-server-tls -n gloo-mesh

    kubectl --context ${EAST_CONTEXT} delete secret vault-token -n gloo-mesh
    kubectl --context ${EAST_CONTEXT} delete secret relay-client-tls-secret -n gloo-mesh
    kubectl --context ${EAST_CONTEXT} delete issuer vault-issuer -n gloo-mesh
    kubectl --context ${EAST_CONTEXT} delete certificate relay-client-tls -n gloo-mesh

    kubectl --context ${WEST_CONTEXT} delete secret vault-token -n gloo-mesh
    kubectl --context ${WEST_CONTEXT} delete secret relay-client-tls-secret -n gloo-mesh
    kubectl --context ${WEST_CONTEXT} delete issuer vault-issuer -n gloo-mesh
    kubectl --context ${WEST_CONTEXT} delete certificate relay-client-tls -n gloo-mesh
}

shift $((OPTIND-1))
subcommand=$1; shift
case "$subcommand" in
    gen )
        generate
    ;;
    del )
        delete
    ;;
    * ) # Invalid subcommand
        if [ ! -z $subcommand ]; then
            echo "Invalid subcommand: $subcommand"
        fi
        exit 1
    ;;
esac
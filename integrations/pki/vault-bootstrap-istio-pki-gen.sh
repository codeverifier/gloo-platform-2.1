#!/bin/bash

###################################################################
# Script Name   : vault-bootstrap-istio-pki-gen.sh
# Description   : Manage Istio PKI integration with Vault
# Author        : Kasun Talwatta
# Email         : kasun.talwatta@solo.io
###################################################################

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

check_vault_status() {
    vault status &> /dev/null
    while [[ $? -ne 0 ]]; do !!; sleep 5; done
}

generate() {
    echo "------------------------------------------------------------"
    echo "Bootstrapping the istio PKI"
    echo "------------------------------------------------------------"
    echo ""

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

    CERT_GEN_DIR=$DIR/../../_output/certs/istio
    mkdir -p $CERT_GEN_DIR

    # Generate offline root CA (10 year expiry)
    cfssl genkey \
      -initca $DIR/istio/root-template.json | cfssljson -bare $CERT_GEN_DIR/root-cert

    cat $CERT_GEN_DIR/root-cert-key.pem $CERT_GEN_DIR/root-cert.pem > $CERT_GEN_DIR/root-bundle.pem

    # Enable PKI engine
    vault secrets enable pki

    # Import Root CA
    vault write -format=json pki/config/ca pem_bundle=@$CERT_GEN_DIR/root-bundle.pem

    # ---------------------------------------
    # ------------ For East Mesh ------------
    # ---------------------------------------
    # Enable PKI for east mesh (intermediate signing)
    vault secrets enable -path=istio-east-mesh-pki-int pki

    # Tune with 3 years TTL
    vault secrets tune -max-lease-ttl="26280h" istio-east-mesh-pki-int

    # Policy for intermediate signing
    vault policy write gen-int-ca-istio-east-mesh - <<EOF
path "istio-east-mesh-pki-int/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "pki/cert/ca" {
  capabilities = ["read"]
}
path "pki/root/sign-intermediate" {
  capabilities = ["create", "read", "update", "list"]
}
EOF

    # Enable Kubernetes authentication
    vault auth enable -path=kube-east-mesh-auth kubernetes

    # Policy for intermediate signing
    VAULT_SA_NAME=$(kubectl --context $EAST_CONTEXT get sa istiod-$REVISION -n istio-system \
      -o jsonpath="{.secrets[*]['name']}")
    SA_TOKEN=$(kubectl --context $EAST_CONTEXT get secret $VAULT_SA_NAME -n istio-system \
      -o 'go-template={{ .data.token }}' | base64 --decode)
    SA_CA_CRT=$(kubectl config view --raw -o json \
      | jq -r --arg wc $EAST_CONTEXT '. as $c | $c.contexts[] | select(.name == $wc) as $context | $c.clusters[] | select(.name == $context.context.cluster) | .cluster."certificate-authority-data"' \
      | base64 -d) 
    K8S_ADDR=$(kubectl config view -o json \
      | jq -r --arg wc $EAST_CONTEXT '. as $c | $c.contexts[] | select(.name == $wc) as $context | $c.clusters[] | select(.name == $context.context.cluster) | .cluster.server')

    # Set Kubernetes auth config for Vault to the mounted token
    vault write auth/kube-east-mesh-auth/config \
      token_reviewer_jwt="$SA_TOKEN" \
      kubernetes_host="$K8S_ADDR" \
      kubernetes_ca_cert="$SA_CA_CRT" \
      issuer="https://kubernetes.default.svc.cluster.local"

    # Bind the istiod service account to the PKI policy
    vault write \
      auth/kube-east-mesh-auth/role/gen-int-ca-istio-east-mesh \
      bound_service_account_names=istiod-$REVISION \
      bound_service_account_namespaces=istio-system \
      policies=gen-int-ca-istio-east-mesh \
      ttl=720h

    # ---------------------------------------
    # ------------ For West Mesh ------------
    # ---------------------------------------
    # Enable PKI for west mesh (intermediate signing)
    vault secrets enable -path=istio-west-mesh-pki-int pki

    # Tune with 3 years TTL
    vault secrets tune -max-lease-ttl="26280h" istio-west-mesh-pki-int

    vault policy write gen-int-ca-istio-west-mesh - <<EOF
path "istio-west-mesh-pki-int/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "pki/cert/ca" {
  capabilities = ["read"]
}
path "pki/root/sign-intermediate" {
  capabilities = ["create", "read", "update", "list"]
}
EOF

    # Enable Kubernetes authentication
    vault auth enable -path=kube-west-mesh-auth kubernetes

    VAULT_SA_NAME=$(kubectl --context $WEST_CONTEXT get sa istiod-$REVISION -n istio-system \
      -o jsonpath="{.secrets[*]['name']}")
    SA_TOKEN=$(kubectl --context $WEST_CONTEXT get secret $VAULT_SA_NAME -n istio-system \
      -o 'go-template={{ .data.token }}' | base64 --decode)
    SA_CA_CRT=$(kubectl config view --raw -o json \
      | jq -r --arg wc $WEST_CONTEXT '. as $c | $c.contexts[] | select(.name == $wc) as $context | $c.clusters[] | select(.name == $context.context.cluster) | .cluster."certificate-authority-data"' \
      | base64 -d) 
    K8S_ADDR=$(kubectl config view -o json \
      | jq -r --arg wc $WEST_CONTEXT '. as $c | $c.contexts[] | select(.name == $wc) as $context | $c.clusters[] | select(.name == $context.context.cluster) | .cluster.server')

    # Set Kubernetes auth config for Vault to the mounted token
    vault write auth/kube-west-mesh-auth/config \
      token_reviewer_jwt="$SA_TOKEN" \
      kubernetes_host="$K8S_ADDR" \
      kubernetes_ca_cert="$SA_CA_CRT" \
      issuer="https://kubernetes.default.svc.cluster.local"

    # Bind the istiod service account to the PKI policy
    vault write \
      auth/kube-west-mesh-auth/role/gen-int-ca-istio-west-mesh \
      bound_service_account_names=istiod-$REVISION \
      bound_service_account_namespaces=istio-system \
      policies=gen-int-ca-istio-west-mesh \
      ttl=720h

    rm -f root-cert-key.pem
    rm -f root-bundle.pem
}

delete() {
    echo "Cleaning up ..."

    rm -rf $CERT_GEN_DIR
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
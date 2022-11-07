#!/bin/bash

###################################################################
# Script Name   : install.sh
# Description   : Provision a Gloo Mesh multi-cluster environment
# Author        : Kasun Talwatta
# Email         : kasun.talwatta@solo.io
###################################################################

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

error_exit() {
    echo "Error: $1"
    exit 1
}

print_info() {
    echo "============================================================"
    echo "$1"
    echo "============================================================"
    echo ""
}

debug() {
    echo ""
    echo "$1"
    echo ""
}

wait_for_lb_address() {
    local context=$1
    local service=$2
    local ns=$3
    ip=""
    while [ -z $ip ]; do
        echo "Waiting for $service external IP ..."
        ip=$(kubectl --context ${context} -n $ns get service/$service --output=jsonpath='{.status.loadBalancer}' | grep "ingress")
        [ -z "$ip" ] && sleep 5
    done
    echo "Found $service external IP: ${ip}"
}

prechecks() {
    if [[ -z "${EAST_CONTEXT}" || -z "${WEST_CONTEXT}" || -z "${MGMT_CONTEXT}" ]]; then
        error_exit "Kubernetes contexts not set. Please set environment variables, \$EAST_CONTEXT, \$WEST_CONTEXT, and \$MGMT_CONTEXT."
    fi

    if [[ -z "${EAST_CLOUD_PROVIDER}" || -z "${WEST_CLOUD_PROVIDER}" || -z "${MGMT_CLOUD_PROVIDER}" ]]; then
        error_exit "Cloud provider not set. Please set environment variables, \$EAST_CLOUD_PROVIDER, \$WEST_CLOUD_PROVIDER, and \$MGMT_CLOUD_PROVIDER."
    fi

    if [[ -z "${EAST_MESH_NAME}" || -z "${WEST_MESH_NAME}" || -z "${MGMT_MESH_NAME}" ]]; then
        error_exit "Cluster names are not set. Please set environment variables, \$EAST_MESH_NAME, \$WEST_MESH_NAME, and \$MGMT_MESH_NAME."
    fi

    if [[ -z "${GLOO_MESH_VERSION}" || -z "${GLOO_MESH_HELM_VERSION}" ]]; then
        error_exit "Gloo Mesh version is not set. Please set environment variable, \$GLOO_MESH_VERSION."
    fi

    if [[ -z "${ISTIO_VERSION}" || -z "${ISTIO_HELM_VERSION}" || -z "${REVISION}" || -z "${ISTIO_SOLO_VERSION}" || -z "${ISTIO_SOLO_REPO}" ]]; then
        error_exit "Istio version details not set. Please set environment variables, \$ISTIO_VERSION, \$ISTIO_SOLO_REPO, \$REVISION."
    fi

    if [[ -z "${GLOO_MESH_GATEWAY_LICENSE_KEY}" ]]; then
        error_exit "Gloo Mesh license key not set. Please set environment variables, \$GLOO_MESH_GATEWAY_LICENSE_KEY"
    fi
}

install_istio() {
    print_info "Installing Istio on all the worker clusters"

    helm repo add istio https://istio-release.storage.googleapis.com/charts
    helm repo update

    kubectl --context $WEST_CONTEXT create ns istio-config
    kubectl --context $EAST_CONTEXT create ns istio-config

    debug "Installing Istio base on worker clusters ...."
    envsubst < <(cat $DIR/core/istio/base-helm-values.yaml) | helm --kube-context ${WEST_CONTEXT} install istio-base istio/base \
        -n istio-system \
        --version $ISTIO_HELM_VERSION \
        --create-namespace -f -
    envsubst < <(cat $DIR/core/istio/base-helm-values.yaml) | helm --kube-context ${EAST_CONTEXT} install istio-base istio/base \
        -n istio-system \
        --version $ISTIO_HELM_VERSION \
        --create-namespace -f -

    debug "Installing Istio control plane on worker clusters ...."
    CLUSTER_NAME=$WEST_MESH_NAME envsubst < <(cat $DIR/core/istio/istiod-helm-values.yaml) | helm --kube-context ${WEST_CONTEXT} install istiod istio/istiod \
        -n istio-system \
        --version $ISTIO_HELM_VERSION \
        --create-namespace -f -
    CLUSTER_NAME=$EAST_MESH_NAME envsubst < <(cat $DIR/core/istio/istiod-helm-values.yaml) | helm --kube-context ${EAST_CONTEXT} install istiod istio/istiod \
        -n istio-system \
        --version $ISTIO_HELM_VERSION \
        --create-namespace -f -
    kubectl --context ${WEST_CONTEXT} \
        -n istio-system wait deploy/istiod-${REVISION} --for condition=Available=True --timeout=90s
    kubectl --context ${EAST_CONTEXT} \
        -n istio-system wait deploy/istiod-${REVISION} --for condition=Available=True --timeout=90s

    debug "Installing Istio ingress gateways on worker clusters ...."
    CLUSTER_NAME=$WEST_MESH_NAME envsubst < <(cat $DIR/core/istio/ingress-gateway-helm-values.yaml) | helm --kube-context ${WEST_CONTEXT} install istio-ingressgateway istio/gateway \
        -n istio-ingress \
        --version $ISTIO_HELM_VERSION \
        --post-renderer $DIR/core/istio/kustomize/gateways/kustomize \
        --create-namespace -f -
    CLUSTER_NAME=$EAST_MESH_NAME envsubst < <(cat $DIR/core/istio/ingress-gateway-helm-values.yaml) | helm --kube-context ${EAST_CONTEXT} install istio-ingressgateway istio/gateway \
        -n istio-ingress \
        --version $ISTIO_HELM_VERSION \
        --post-renderer $DIR/core/istio/kustomize/gateways/kustomize \
        --create-namespace -f -
    kubectl --context ${WEST_CONTEXT} \
        -n istio-ingress wait deploy/istio-ingressgateway --for condition=Available=True --timeout=90s
    kubectl --context ${EAST_CONTEXT} \
        -n istio-ingress wait deploy/istio-ingressgateway --for condition=Available=True --timeout=90s

    debug "Installing Istio east/west gateways on worker clusters ...."
    CLUSTER_NAME=$WEST_MESH_NAME envsubst < <(cat $DIR/core/istio/eastwest-gateway-helm-values.yaml) | helm --kube-context ${WEST_CONTEXT} install istio-eastwestgateway istio/gateway \
        -n istio-eastwest \
        --version $ISTIO_HELM_VERSION \
        --post-renderer $DIR/core/istio/kustomize/gateways/kustomize \
        --create-namespace -f -
    CLUSTER_NAME=$EAST_MESH_NAME envsubst < <(cat $DIR/core/istio/eastwest-gateway-helm-values.yaml) | helm --kube-context ${EAST_CONTEXT} install istio-eastwestgateway istio/gateway \
        -n istio-eastwest \
        --version $ISTIO_HELM_VERSION \
        --post-renderer $DIR/core/istio/kustomize/gateways/kustomize \
        --create-namespace -f -
    kubectl --context ${WEST_CONTEXT} \
        -n istio-eastwest wait deploy/istio-eastwestgateway --for condition=Available=True --timeout=90s
    kubectl --context ${EAST_CONTEXT} \
        -n istio-eastwest wait deploy/istio-eastwestgateway --for condition=Available=True --timeout=90s
}

configure_federation() {
    kubectl --context ${MGMT_CONTEXT} apply -f $DIR/core/gloo-mesh/federation/federated-trust-policy.yaml
}

update_install_with_vault_support() {
    print_info "Updating Istio with Vault support on all the worker clusters"

    # ------ Federation for west cluster
    envsubst < <(cat $DIR/core/gloo-mesh/federation/federated-west-mesh-trust-policy.yaml) | kubectl --context ${WEST_CONTEXT} apply -f -
    # Upgrade Istio control plane with Vault sidecars
    CLUSTER_NAME=$WEST_MESH_NAME envsubst < <(cat $DIR/core/istio/istiod-helm-values.yaml) | helm --kube-context ${WEST_CONTEXT} upgrade istiod istio/istiod \
        -n istio-system \
        --version $ISTIO_HELM_VERSION \
        --post-renderer $DIR/core/istio/kustomize/istiod/kustomize \
        --wait \
        --timeout 5m0s \
        -f -
    sleep 10
    # Restart control plane
    kubectl --context ${WEST_CONTEXT} \
        -n istio-system rollout restart deploy/istiod-${REVISION}
    kubectl --context ${WEST_CONTEXT} \
        -n istio-system rollout status deploy/istiod-${REVISION} --timeout=90s
    sleep 5
    # Restart all the gateways
    kubectl --context ${WEST_CONTEXT} \
        -n istio-ingress rollout restart deploy/istio-ingressgateway 
    kubectl --context ${WEST_CONTEXT} \
        -n istio-eastwest rollout restart deploy/istio-eastwestgateway
    # And the rest
    kubectl --context ${WEST_CONTEXT} \
        -n gloo-mesh-addons rollout restart deploy/rate-limiter
    kubectl --context ${WEST_CONTEXT} \
        -n gloo-mesh-addons rollout restart deploy/redis
    kubectl --context ${WEST_CONTEXT} \
        -n gloo-mesh-addons rollout restart deploy/ext-auth-service

    # ------ Federation for east cluster
    envsubst < <(cat $DIR/core/gloo-mesh/federation/federated-east-mesh-trust-policy.yaml) | kubectl --context ${EAST_CONTEXT} apply -f -
    # Upgrade Istio control plane with Vault sidecars
    CLUSTER_NAME=$EAST_MESH_NAME envsubst < <(cat $DIR/core/istio/istiod-helm-values.yaml) | helm --kube-context ${EAST_CONTEXT} upgrade istiod istio/istiod \
        -n istio-system \
        --version $ISTIO_HELM_VERSION \
        --post-renderer $DIR/core/istio/kustomize/istiod/kustomize \
        --wait \
        --timeout 5m0s \
        -f -
    sleep 10
    # Restart control plane
    kubectl --context ${EAST_CONTEXT} \
        -n istio-system rollout restart deploy/istiod-${REVISION}
    kubectl --context ${EAST_CONTEXT} \
        -n istio-system rollout status deploy/istiod-${REVISION} --timeout=90s
    sleep 5
    # Restart all the gateways
    kubectl --context ${EAST_CONTEXT} \
        -n istio-ingress rollout restart deploy/istio-ingressgateway
    kubectl --context ${EAST_CONTEXT} \
        -n istio-eastwest rollout restart deploy/istio-eastwestgateway
    # And the rest
    kubectl --context ${EAST_CONTEXT} \
        -n gloo-mesh-addons rollout restart deploy/rate-limiter
    kubectl --context ${EAST_CONTEXT} \
        -n gloo-mesh-addons rollout restart deploy/redis
    kubectl --context ${EAST_CONTEXT} \
        -n gloo-mesh-addons rollout restart deploy/ext-auth-service
}

install_gloo_mesh() {
    should_support_vault=$1
    print_info "Installing Gloo Mesh on all the clusters"

    helm repo add gloo-mesh-enterprise https://storage.googleapis.com/gloo-mesh-enterprise/gloo-mesh-enterprise 
    helm repo update
    helm pull gloo-mesh-enterprise/gloo-mesh-enterprise --version $GLOO_MESH_HELM_VERSION --untar
    kubectl --context ${MGMT_CONTEXT} apply -f gloo-mesh-enterprise/charts/gloo-mesh-crds/crds
    rm -rf gloo-mesh-enterprise

    if [[ "$should_support_vault" == true ]]; then
        envsubst < <(cat $DIR/core/gloo-mesh/gloo-mesh-mgmt-plane-disabled-self-ca-2.1.yaml) | helm install gloo-mesh-enterprise gloo-mesh-enterprise/gloo-mesh-enterprise \
            --kube-context ${MGMT_CONTEXT} \
            --namespace gloo-mesh \
            --version ${GLOO_MESH_HELM_VERSION} \
            --create-namespace \
            -f -
    else
        envsubst < <(cat $DIR/core/gloo-mesh/gloo-mesh-mgmt-plane-2.1.yaml) | helm install gloo-mesh-enterprise gloo-mesh-enterprise/gloo-mesh-enterprise \
            --kube-context ${MGMT_CONTEXT} \
            --namespace gloo-mesh \
            --version ${GLOO_MESH_HELM_VERSION} \
            --create-namespace \
            -f -
    fi

    kubectl --context ${MGMT_CONTEXT} \
        -n gloo-mesh wait deploy/gloo-mesh-mgmt-server --for condition=Available=True --timeout=90s

    wait_for_lb_address $MGMT_CONTEXT "gloo-mesh-mgmt-server" "gloo-mesh"

    export ENDPOINT_GLOO_MESH=$(kubectl --context ${MGMT_CONTEXT} -n gloo-mesh get svc gloo-mesh-mgmt-server -o jsonpath='{.status.loadBalancer.ingress[0].*}'):9900
    export HOST_GLOO_MESH=$(echo ${ENDPOINT_GLOO_MESH} | cut -d: -f1)

    kubectl apply --context ${MGMT_CONTEXT} -f- <<EOF
apiVersion: admin.gloo.solo.io/v2
kind: KubernetesCluster
metadata:
  name: ${EAST_MESH_NAME}
  namespace: gloo-mesh
spec:
  clusterDomain: cluster.local
EOF

    kubectl apply --context ${MGMT_CONTEXT} -f- <<EOF
apiVersion: admin.gloo.solo.io/v2
kind: KubernetesCluster
metadata:
  name: ${WEST_MESH_NAME}
  namespace: gloo-mesh
spec:
  clusterDomain: cluster.local
EOF

    if [[ "$should_support_vault" == false ]]; then
        mkdir -p $DIR/_output/gm
        kubectl --context ${EAST_CONTEXT} create ns gloo-mesh
        kubectl --context ${MGMT_CONTEXT} get secret relay-root-tls-secret -n gloo-mesh -o jsonpath='{.data.ca\.crt}' | base64 -d > $DIR/_output/gm/ca.crt
        kubectl --context ${EAST_CONTEXT} create secret generic relay-root-tls-secret -n gloo-mesh --from-file ca.crt=$DIR/_output/gm/ca.crt
        rm $DIR/_output/gm/ca.crt

        kubectl --context ${MGMT_CONTEXT} get secret relay-identity-token-secret -n gloo-mesh -o jsonpath='{.data.token}' | base64 -d > $DIR/_output/gm/token
        kubectl --context ${EAST_CONTEXT} create secret generic relay-identity-token-secret -n gloo-mesh --from-file token=$DIR/_output/gm/token
        rm $DIR/_output/gm/token

        kubectl --context ${WEST_CONTEXT} create ns gloo-mesh
        kubectl get secret relay-root-tls-secret -n gloo-mesh --context ${MGMT_CONTEXT} -o jsonpath='{.data.ca\.crt}' | base64 -d > $DIR/_output/gm/ca.crt
        kubectl create secret generic relay-root-tls-secret -n gloo-mesh --context ${WEST_CONTEXT} --from-file ca.crt=$DIR/_output/gm/ca.crt
        rm $DIR/_output/gm/ca.crt

        kubectl get secret relay-identity-token-secret -n gloo-mesh --context ${MGMT_CONTEXT} -o jsonpath='{.data.token}' | base64 -d > $DIR/_output/gm/token
        kubectl create secret generic relay-identity-token-secret -n gloo-mesh --context ${WEST_CONTEXT} --from-file token=$DIR/_output/gm/token
        rm $DIR/_output/gm/token
    fi

    helm repo add gloo-mesh-agent https://storage.googleapis.com/gloo-mesh-enterprise/gloo-mesh-agent
    helm repo update
    helm pull gloo-mesh-agent/gloo-mesh-agent --version $GLOO_MESH_HELM_VERSION --untar
    kubectl --context ${EAST_CONTEXT} apply -f gloo-mesh-agent/charts/gloo-mesh-crds/crds
    rm -rf gloo-mesh-agent

    helm install gloo-mesh-agent gloo-mesh-agent/gloo-mesh-agent \
        --kube-context=${EAST_CONTEXT} \
        --namespace gloo-mesh \
        --set cluster=${EAST_MESH_NAME} \
        --set relay.serverAddress=${ENDPOINT_GLOO_MESH} \
        --version $GLOO_MESH_HELM_VERSION \
        --create-namespace \
        -f $DIR/core/gloo-mesh/gloo-mesh-agent-2.1.yaml

    kubectl --context ${EAST_CONTEXT} \
        -n gloo-mesh wait deploy/gloo-mesh-agent --for condition=Available=True --timeout=90s

    helm pull gloo-mesh-agent/gloo-mesh-agent --version $GLOO_MESH_HELM_VERSION --untar
    kubectl --context ${WEST_CONTEXT} apply -f gloo-mesh-agent/charts/gloo-mesh-crds/crds
    rm -rf gloo-mesh-agent

    helm install gloo-mesh-agent gloo-mesh-agent/gloo-mesh-agent \
        --kube-context=${WEST_CONTEXT} \
        --namespace gloo-mesh \
        --set cluster=${WEST_MESH_NAME} \
        --set relay.serverAddress=${ENDPOINT_GLOO_MESH} \
        --version $GLOO_MESH_HELM_VERSION \
        --create-namespace \
        -f $DIR/core/gloo-mesh/gloo-mesh-agent-2.1.yaml

    kubectl --context ${WEST_CONTEXT} \
        -n gloo-mesh wait deploy/gloo-mesh-agent --for condition=Available=True --timeout=90s

    kubectl --context ${EAST_CONTEXT} create namespace gloo-mesh-addons
    kubectl --context ${EAST_CONTEXT} label namespace gloo-mesh-addons istio.io/rev=$REVISION
    kubectl --context ${WEST_CONTEXT} create namespace gloo-mesh-addons
    kubectl --context ${WEST_CONTEXT} label namespace gloo-mesh-addons istio.io/rev=$REVISION

    helm install gloo-mesh-agent-addons gloo-mesh-agent/gloo-mesh-agent \
        --kube-context=${EAST_CONTEXT} \
        --namespace gloo-mesh-addons \
        --set glooMeshAgent.enabled=false \
        --set rate-limiter.enabled=true \
        --set ext-auth-service.enabled=true \
        --version $GLOO_MESH_HELM_VERSION

    helm install gloo-mesh-agent-addons gloo-mesh-agent/gloo-mesh-agent \
        --kube-context=${WEST_CONTEXT} \
        --namespace gloo-mesh-addons \
        --set glooMeshAgent.enabled=false \
        --set rate-limiter.enabled=true \
        --set ext-auth-service.enabled=true \
        --version $GLOO_MESH_HELM_VERSION
}

# Create a temp dir (for any internally generated files)
mkdir -p $DIR/_output

# Run prechecks to begin with
prechecks

should_support_vault=false
should_deploy_integrations=false

SHORT=v,i,h
LONG=vault,integrations,help
OPTS=$(getopt -a -n "install.sh" --options $SHORT --longoptions $LONG -- "$@")

eval set -- "$OPTS"

while : 
do
  case "$1" in
    -v | --vault )
      shift 1
      should_support_vault=true
      ;;
    -i | --integrations )
      shift 1
      should_deploy_integrations=true
      ;;
    -h | --help)
      help
      ;;
    --)
      shift;
      break
      ;;
    *)
      echo "Unexpected option: $1"
      help
      ;;
  esac
done

echo -n "Deploying Gloo Mesh (and Istio)"
if [[ "$should_support_vault" == true ]]; then
    echo " with Vault support"
else
    echo ""
fi
echo ""

if [[ "$should_deploy_integrations" == true ]]; then
   $DIR/integrations/provision-integrations.sh -p $EAST_CLOUD_PROVIDER -c $EAST_CONTEXT -n $EAST_CLUSTER -s cert_manager
   $DIR/integrations/provision-integrations.sh -p $WEST_CLOUD_PROVIDER -c $WEST_CONTEXT -n $WEST_CLUSTER -s alb,external_dns,cert_manager
   $DIR/integrations/provision-integrations.sh -p $MGMT_CLOUD_PROVIDER -c $MGMT_CONTEXT -n $MGMT_CLUSTER -s alb,external_dns,cert_manager,grafana,keycloak,argocd,gitea
fi

if [[ "$should_support_vault" == true ]]; then
    $DIR/integrations/provision-integrations.sh -p $MGMT_CLOUD_PROVIDER -c $MGMT_CONTEXT -n $MGMT_CLUSTER -s vault

    if [[ -f $DIR/_output/vault_env.sh ]]; then
        source $DIR/_output/vault_env.sh
    else
        error_exit "Unable to find 'vault_env.sh'"
    fi

    $DIR/integrations/pki/vault-bootstrap-relay-pki-gen.sh gen
fi

install_istio

if [[ "$should_support_vault" == true ]]; then
    if [[ -f $DIR/_output/vault_env.sh ]]; then
        source $DIR/_output/vault_env.sh
    else
        error_exit "Unable to find 'vault_env.sh'"
    fi

    $DIR/integrations/pki/vault-bootstrap-istio-pki-gen.sh gen
fi

install_gloo_mesh $should_support_vault
sleep 10

if [[ "$should_support_vault" == true ]]; then
    update_install_with_vault_support
else
    # Federate with self service CA
    # Auto restart of Istio is enabled
    configure_federation
fi
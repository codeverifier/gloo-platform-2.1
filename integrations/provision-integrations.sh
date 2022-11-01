#!/bin/bash

###################################################################
# Script Name   : provision-integrations.sh
# Description   : Provision required integrations
# Author        : Kasun Talwatta
# Email         : kasun.talwatta@solo.io
###################################################################

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

error_exit() {
    echo "Error: $1"
    exit 1
}

error() {
    echo "Error: $1"
}

print_info() {
    echo ""
    echo "============================================================"
    echo "$1"
    echo "============================================================"
    echo ""
}

validate_env_var() {
    [[ -z ${!1+set} ]] && error_exit "Error: Define ${1} environment variable"

    [[ -z ${!1} ]] && error_exit "${2}"
}

validate_var() {
    [[ -z $1 ]] && error_exit $2
}

has_array_value () {
    local -r item="{$1:?}"
    local -rn items="{$2:?}"

    echo $2

    for value in "${items[@]}"; do
        echo $value
        if [[ "$value" == "$item" ]]; then
            return 0
        fi
    done

    return 1
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

create_aws_identity_provider_and_service_account() {
    local cluster_name=$1
    local policy_name=$2
    local policy_file=$3
    local sa_name=$4
    local sa_namespace=$5
    validate_env_var cluster_name "Cluster name is not set"
    validate_env_var policy_name "Policy name is not set"
    validate_env_var sa_name "Service account name is not set"
    validate_env_var sa_namespace "Namespace for service account is not set"

    eksctl utils associate-iam-oidc-provider \
        --region $EKS_CLUSTER_REGION \
        --cluster ${CLUSTER_OWNER}-${cluster_name} \
        --approve

    aws iam create-policy \
        --policy-name "${CLUSTER_OWNER}_${policy_name}" \
        --policy-document file://$DIR/$policy_file

    # Create an IAM service account
    eksctl create iamserviceaccount \
        --name=${sa_name} \
        --namespace=${sa_namespace} \
        --cluster=${CLUSTER_OWNER}-${cluster_name} \
        --region=$EKS_CLUSTER_REGION \
        --attach-policy-arn=$(aws iam list-policies --output json | jq --arg pn "${CLUSTER_OWNER}_${policy_name}" -r '.Policies[] | select(.PolicyName == $pn)'.Arn) \
        --override-existing-serviceaccounts \
        --approve
}

install_alb_controller() {
    local context=$1
    local cluster_name=$2
    local sa_namespace="kube-system"

    print_info "Installing ALB Controller on ${context} cluster"

    validate_env_var context "Kubernetes context not set"
    validate_env_var cluster_name "Cluster name not set"

    # Create an IAM OIDC identity provider and policy
    create_aws_identity_provider_and_service_account $cluster_name \
        "AWSLoadBalancerControllerIAMPolicy" "alb-controller/iam-policy.json" "aws-load-balancer-controller" $sa_namespace

    # Get the VPC ID
    export VPC_ID=$(aws ec2 describe-vpcs --region $EKS_CLUSTER_REGION \
        --filters Name=tag:Name,Values=eksctl-${CLUSTER_OWNER}-${cluster_name}-cluster/VPC | jq -r '.Vpcs[]|.VpcId')

    # Install ALB controller
    helm repo add eks https://aws.github.io/eks-charts
    helm repo update

    export CLUSTER_NAME=$cluster_name
    envsubst < <(cat $DIR/alb-controller/alb-controller-helm-values.yaml) | helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
        --kube-context ${context} \
        -n ${sa_namespace} -f -

    kubectl --context ${context} \
        -n kube-system wait deploy/aws-load-balancer-controller --for condition=Available=True --timeout=90s
}

install_external_dns() {
    local context=$1
    local cluster_name=$2
    local cluster_provider=$3
    local sa_namespace="external-dns"

    print_info "Installing External DNS on ${context} cluster"

    validate_env_var context "Kubernetes context not set"
    validate_env_var cluster_name "Cluster name not set"
    validate_env_var PARENT_DOMAIN_NAME "Parent domain name is not set"
    validate_env_var DOMAIN_NAME "Domain name is not set"

    if [[ "$cluster_provider" == "eks" ]]; then
        # Create an IAM OIDC identity provider and policy
        create_aws_identity_provider_and_service_account $cluster_name \
            "AWSExternalDNSRoute53Policy" "external-dns/iam-policy.json" "external-dns" $sa_namespace

        # If the hosted zone doesnt exist then create it
        if ! aws route53 list-hosted-zones-by-name --output json --dns-name "$DOMAIN_NAME." > /dev/null 2>&1; then
            # Create the hosted zone
            aws route53 create-hosted-zone --name "$DOMAIN_NAME." --caller-reference "${CLUSTER_OWNER}-${cluster_name}-$(date +%s)"

            # Add the nameservers to the top level zone
            local top_level_hosted_zone_id=$(aws route53 list-hosted-zones-by-name --output json --dns-name "$PARENT_DOMAIN_NAME." | jq -r '.HostedZones[0].Id')
            export HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name --output json --dns-name "$DOMAIN_NAME." | jq -r '.HostedZones[0].Id')
            local ns_list=$(aws route53 list-resource-record-sets --output json --hosted-zone-id "$HOSTED_ZONE_ID" \
                | jq -r '.ResourceRecordSets' | jq -r 'map(select(.Type == "NS"))' | jq -r '.[0].ResourceRecords')

            aws route53 change-resource-record-sets \
                --hosted-zone-id "$top_level_hosted_zone_id" \
                --change-batch file://<(cat << EOF
{
    "Comment": "$DOMAIN_NAME nameservers",
    "Changes": [
        {
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": "$DOMAIN_NAME",
                "Type": "NS",
                "TTL": 120,
                "ResourceRecords": $ns_list
            }
        }
    ]
}
EOF
            )
        fi
    elif [[ "$cluster_provider" == "gke" ]]; then
        export MANAGED_ZONE_NAME=$(echo ${DOMAIN_NAME} | sed 's/\./-/g')
        if ! gcloud dns record-sets list --zone "$MANAGED_ZONE_NAME" --name "${DOMAIN_NAME}." > /dev/null 2>&1; then
            gcloud dns managed-zones create "$MANAGED_ZONE_NAME" --dns-name "${DOMAIN_NAME}." \
                --description "Automatically managed zone by kubernetes.io/external-dns"
            local ns_list=$(gcloud dns record-sets list \
                --zone "$MANAGED_ZONE_NAME" --name "${DOMAIN_NAME}." --type NS --format json | jq -r '.[].rrdatas | to_entries | map( {Value: .value} )')

            # Add record and NS's to top level domain
            local top_level_hosted_zone_id=$(aws route53 list-hosted-zones-by-name --output json --dns-name "$PARENT_DOMAIN_NAME." | jq -r '.HostedZones[0].Id')
            aws route53 change-resource-record-sets \
                --hosted-zone-id "$top_level_hosted_zone_id" \
                --change-batch file://<(cat << EOF
{
    "Comment": "$DOMAIN_NAME nameservers",
    "Changes": [
        {
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": "$DOMAIN_NAME",
                "Type": "NS",
                "TTL": 120,
                "ResourceRecords": $ns_list
            }
        }
    ]
}
EOF
        )
        fi
    fi

    # Deploy External DNS
    helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/
    helm repo update

    if [[ "$cluster_provider" == "eks" ]]; then
        envsubst < <(cat $DIR/external-dns/external-dns-eks-helm-values.yaml) | helm install external-dns external-dns/external-dns \
            --kube-context ${context} \
            --create-namespace \
            -n external-dns -f -
    elif [[ "$cluster_provider" == "gke" ]]; then
        envsubst < <(cat $DIR/external-dns/external-dns-gke-helm-values.yaml) | helm install external-dns external-dns/external-dns \
            --kube-context ${context} \
            --create-namespace \
            -n external-dns -f -
    fi

    kubectl --context ${context} \
        -n external-dns wait deploy/external-dns --for condition=Available=True --timeout=90s
}

install_cert_manager() {
    local context=$1
    local cluster_name=$2
    local cluster_provider=$3
    local sa_namespace="cert-manager"

    print_info "Installing Cert Manager on ${context} cluster"

    validate_env_var context "Kubernetes context not set"
    validate_env_var cluster_name "Cluster name not set"
    validate_env_var cluster_provider "Cluster provider not set"
    validate_env_var CERT_MANAGER_VERSION "Cert manager version is not set with \$CERT_MANAGER_VERSION"

    if [[ "$cluster_provider" == "eks" ]]; then
        # Create an IAM OIDC identity provider and policy
        create_aws_identity_provider_and_service_account $cluster_name \
            "AWSCertManagerRoute53IAMPolicy" "cert-manager/iam-policy.json" "cert-manager" $sa_namespace
    elif [[ "$cluster_provider" == "gke" ]]; then
        export PROJECT_ID=$(gcloud config get-value project)
        gcloud iam service-accounts create cert-manager-dns01-solver \
            --display-name "cert-manager-dns01-solver"
        gcloud projects add-iam-policy-binding $PROJECT_ID \
            --member serviceAccount:cert-manager-dns01-solver@$PROJECT_ID.iam.gserviceaccount.com \
            --role roles/dns.admin
        gcloud iam service-accounts keys create $DIR/../_output/dns01-solver_key.json \
            --iam-account cert-manager-dns01-solver@$PROJECT_ID.iam.gserviceaccount.com
        kubectl --context ${context} -n cert-manager create secret generic clouddns-dns01-solver-svc-acct \
            --from-file=key.json=$DIR/../_output/dns01-solver_key.json
    fi

    # Deploy Cert manager
    helm repo add jetstack https://charts.jetstack.io
    helm repo update

    kubectl --context ${context} \
        apply -f https://github.com/cert-manager/cert-manager/releases/download/$CERT_MANAGER_VERSION/cert-manager.crds.yaml

    if [[ "$cluster_provider" == "eks" ]]; then
        helm install cert-manager jetstack/cert-manager -n cert-manager \
            --kube-context ${context} \
            --create-namespace \
            --version ${CERT_MANAGER_VERSION} \
            -f $DIR/cert-manager/cert-manager-aws-helm-values.yaml
    else
        helm install cert-manager jetstack/cert-manager -n cert-manager \
            --kube-context ${context} \
            --create-namespace \
            --version ${CERT_MANAGER_VERSION} \
            -f $DIR/cert-manager/cert-manager-helm-values.yaml
    fi

    kubectl --context ${context} \
        -n cert-manager wait deploy/cert-manager --for condition=Available=True --timeout=90s
    kubectl --context ${context} \
        -n cert-manager wait deploy/cert-manager-cainjector --for condition=Available=True --timeout=90s
    kubectl --context ${context} \
        -n cert-manager wait deploy/cert-manager-webhook --for condition=Available=True --timeout=90s

    # Cluster wide issuer
    if [[ "$cluster_provider" == "eks" ]]; then
        export CLUSTER_REGION=EKS_CLUSTER_REGION
        envsubst < <(cat $DIR/cert-manager/certificate-issuer-eks.yaml) | kubectl --context ${context} apply -f -
    elif [[ "$cluster_provider" == "gke" ]]; then
        envsubst < <(cat $DIR/cert-manager/certificate-issuer-gke.yaml) | kubectl --context ${context} apply -f -
    fi
}

install_vault() {
    print_info "Installing Vault on management cluster"

    local context=$1

    validate_env_var context "Kubernetes context is not set"
    validate_env_var VAULT_VERSION "Vault version is not specified as \$VAULT_VERSION environment variable"

    # Deploy Vault
    helm repo add hashicorp https://helm.releases.hashicorp.com
    helm repo update

    helm install vault hashicorp/vault -n vault \
        --kube-context ${context} \
        --version ${VAULT_VERSION} \
        --create-namespace \
        -f $DIR/vault/vault-helm-values.yaml

    # Wait for vault to be ready
    kubectl --context ${context} wait --for=condition=ready pod vault-0 -n vault

    wait_for_lb_address $context "vault" "vault"

    export VAULT_LB=$(kubectl --context ${context} get svc -n vault vault \
        -o jsonpath='{.status.loadBalancer.ingress[0].*}') 
    validate_env_var VAULT_LB "Unable to get the load balancer address for Vault"
    
    echo export VAULT_LB=$(kubectl --context ${context} get svc -n vault vault \
        -o jsonpath='{.status.loadBalancer.ingress[0].*}') > $DIR/../_output/vault_env.sh
    echo export VAULT_ADDR="http://${VAULT_LB}:8200" >> $DIR/../_output/vault_env.sh
}

install_grafana() {
    print_info "Installing Grafana on management cluster"

    local context=$1
    local localport=3000

    validate_env_var context "Kubernetes context is not set"
    validate_env_var ISTIO_VERSION "Istio version is not set"

    # Install grafana
    kubectl --context ${context} create ns grafana
    kubectl --context ${context} apply -f $DIR/grafana/grafana-deployment.yaml \
        -n grafana

    kubectl --context ${context} \
        -n grafana wait deploy/grafana --for condition=Available=True --timeout=90s

    # Portforward to service
    kubectl --context ${context} -n grafana port-forward svc/grafana $localport:3000 > /dev/null 2>&1 &
    pid=$!

    # Kill the port-forward regardless of how this script exits
    trap '{
        # echo killing $pid
        kill $pid
    }' EXIT

    # Wait for $localport to become available
    while ! nc -vz localhost $localport > /dev/null 2>&1 ; do
        # echo sleeping
        sleep 0.1
    done

    # Address of Grafana
    local grafana_host="http://localhost:3000"
    # The name of the Prometheus data source to use
    local grafana_datasource="Prometheus"

    # Import all Istio dashboards
    for dashboard in 7639 11829 7636 7630 7645; do
        revision="$(curl -s https://grafana.com/api/dashboards/${dashboard}/revisions -s | jq ".items[] | select(.description | contains(\"${ISTIO_VERSION}\")) | .revision")"
        curl -s https://grafana.com/api/dashboards/$dashboard/revisions/$revision/download > /tmp/dashboard.json
        echo "Importing $(cat /tmp/dashboard.json | jq -r '.title') (revision ${revision}, id ${dashboard})..."
        curl -s -k -XPOST \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            -d "{\"dashboard\":$(cat /tmp/dashboard.json),\"overwrite\":true, \
                \"inputs\":[{\"name\":\"DS_PROMETHEUS\",\"type\":\"datasource\", \
                \"pluginId\":\"prometheus\",\"value\":\"$grafana_datasource\"}]}" \
            $grafana_host/api/dashboards/import
        echo -e "\nDone\n"
    done
}

install_keycloak() {
    print_info "Installing Keycloak on management cluster"

    local context=$1
    validate_env_var context "Kubernetes context is not set"

    kubectl --context ${context} create namespace keycloak
    envsubst < <(cat $DIR/keycloak/deploy.yaml) | kubectl --context ${context} -n keycloak apply -f -
    kubectl --context ${context} \
        -n keycloak wait deploy/keycloak --for condition=Available=True --timeout=90s

    wait_for_lb_address $context "keycloak" "keycloak"

    sleep 120

    export ENDPOINT_KEYCLOAK="keycloak.${DOMAIN_NAME}:8080"
    export KEYCLOAK_URL=http://${ENDPOINT_KEYCLOAK}/auth
    echo export KEYCLOAK_URL=$KEYCLOAK_URL > $DIR/../_output/keycloak_env.sh

    export KEYCLOAK_TOKEN=$(curl -d "client_id=admin-cli" -d "username=admin" -d "password=admin" -d "grant_type=password" "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" | jq -r .access_token)
    echo export KEYCLOAK_TOKEN=$KEYCLOAK_TOKEN >> $DIR/../_output/keycloak_env.sh

    # Create initial token to register the client
    read -r client token <<<$(curl -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" -X POST -H "Content-Type: application/json" -d '{"expiration": 0, "count": 1}' $KEYCLOAK_URL/admin/realms/master/clients-initial-access | jq -r '[.id, .token] | @tsv')
    export CLIENT_ID=${client}
    echo export CLIENT_ID=$CLIENT_ID >> $DIR/../_output/keycloak_env.sh

    # Register the client
    read -r id secret <<<$(curl -X POST -d "{ \"clientId\": \"${CLIENT_ID}\" }" -H "Content-Type:application/json" -H "Authorization: bearer ${token}" ${KEYCLOAK_URL}/realms/master/clients-registrations/default| jq -r '[.id, .secret] | @tsv')
    export CLIENT_SECRET=${secret}
    echo export CLIENT_SECRET_BASE64_ENCODED=$(echo -n ${CLIENT_SECRET} | base64) >> $DIR/../_output/keycloak_env.sh

    # Add allowed redirect URIs
    curl -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" -X PUT -H "Content-Type: application/json" \
        -d '{"serviceAccountsEnabled": true, "directAccessGrantsEnabled": true, "authorizationServicesEnabled": true, "redirectUris": ["http://localhost:8090/oidc-callback", "'http://apps.${DOMAIN_NAME}'/callback", "'https://apps.${DOMAIN_NAME}'/callback", "'http://gloo-mesh-ui.${DOMAIN_NAME}'/callback", "'http://api.${DOMAIN_NAME}'/callback", "'https://api.${DOMAIN_NAME}'/callback"]}' \
        $KEYCLOAK_URL/admin/realms/master/clients/${id}

    # Add the group attribute in the JWT token returned by Keycloak
    curl -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" -X POST -H "Content-Type: application/json" \
        -d '{"name": "Groups Mapper", "protocol": "openid-connect", "protocolMapper": "oidc-group-membership-mapper", "config": {"claim.name": "groups", "jsonType.label": "String", "id.token.claim": "true", "access.token.claim": "true", "userinfo.token.claim": "true"}}' \
        $KEYCLOAK_URL/admin/realms/master/clients/${id}/protocol-mappers/models

    # New groups
    curl -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" -X POST -H "Content-Type: application/json" \
        -d '{"name": "dev-team"}' \
        $KEYCLOAK_URL/admin/realms/master/groups
    curl -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" -X POST -H "Content-Type: application/json" \
        -d '{"name": "ops-team"}' \
        $KEYCLOAK_URL/admin/realms/master/groups

    # New users
    curl -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" -X POST -H "Content-Type: application/json" \
        -d '{"username": "dev1", "email": "dev1@solo.io", "firstName": "Dev1", "enabled": true, "groups": ["dev-team"], "emailVerified": true, "credentials": [{"type": "password", "value": "Passwd00", "temporary": false}]}' \
        $KEYCLOAK_URL/admin/realms/master/users

    curl -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" -X POST -H "Content-Type: application/json" \
        -d '{"username": "dev2", "email": "dev2@solo.io", "firstName": "Dev2", "enabled": true, "groups": ["dev-team"], "emailVerified": true, "credentials": [{"type": "password", "value": "Passwd00", "temporary": false}]}' \
        $KEYCLOAK_URL/admin/realms/master/users

    curl -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" -X POST -H "Content-Type: application/json" \
        -d '{"username": "ops1", "email": "ops1@solo.io", "firstName": "Ops1", "enabled": true, "groups": ["ops-team"], "emailVerified": true, "credentials": [{"type": "password", "value": "Passwd00", "temporary": false}]}' \
        $KEYCLOAK_URL/admin/realms/master/users
}

install_argocd() {
    print_info "Installing ArgoCD on management cluster"

    local context=$1

    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo update

    envsubst < <(cat $DIR/argocd/argocd-helm-values.yaml) | helm install argocd argo/argo-cd -n gitops \
        --kube-context=${context} \
        --version ${ARGOCD_VERSION} \
        --create-namespace \
        -f -

    kubectl --context ${context} \
        -n gitops wait deploy/argocd-server --for condition=Available=True --timeout=90s

    wait_for_lb_address $context "argocd-server" "gitops"

    kubectl --context ${context} create ns gloo-mesh

    if [[ -z "${EAST_CONTEXT}" || -z "${WEST_CONTEXT}" ]]; then
        error "Kubernetes contexts not set. Please set environment variables, \$EAST_CONTEXT, \$WEST_CONTEXT."
    else
        if command -v argocd &> /dev/null; then
            if argocd login --plaintext argocd.$DOMAIN_NAME:80 --insecure >& /dev/null; then
                argocd cluster add $WEST_CONTEXT -y
                argocd cluster add $EAST_CONTEXT -y
            else
                error "Unable to register the worker clusters. Please run the following commands,"
                echo "argocd login --plaintext argocd.$DOMAIN_NAME:80 --insecure"
                echo "argocd cluster add $WEST_CONTEXT"
                echo "argocd cluster add $EAST_CONTEXT"
            fi
        else
            error "ArgoCD CLI command not found"
        fi
    fi
}

install_gitea() {
    print_info "Installing Gitea on management cluster"

    local context=$1

    helm repo add gitea-charts https://dl.gitea.io/charts/
    helm repo update

    envsubst < <(cat $DIR/gitea/gitea-helm-values.yaml) | helm install gitea gitea-charts/gitea -n gitops \
        --kube-context=${context} \
        --version ${GITEA_VERSION} \
        --create-namespace \
        -f -

    kubectl --context ${context} \
        -n gitops wait deploy/gitea --for condition=Available=True --timeout=90s

    wait_for_lb_address $context "gitea-http" "gitops"

    # Add the repository
    TOKEN=$(curl -s -XPOST -H "Content-Type: application/json" -k -d '{"name":"Admin API Token"}' -u kasunt:Passwd00 http://git-ui.$DOMAIN_NAME/api/v1/users/kasunt/tokens | jq .sha1 | sed -e 's/"//g')
    curl -v -H "content-type: application/json" -H "Authorization: token $TOKEN" -X POST http://git-ui.$DOMAIN_NAME/api/v1/user/repos -d '{"name": "gloo-mesh-config", "description": "Gloo Mesh configuration", "private": false}'
}

help() {
    cat << EOF
usage: ./provision-integrations.sh
-p | --provider     (Required)      Cloud provider for the cluster (Accepted values: aks, eks, gke)
-c | --context      (Required)      Kubernetes context
-n | --name         (Required)      Cluster name (Used for setting up AWS identity)
-s | --services     (Required)      Comma delimited set of services to deploy (Accepted values: alb, external_dns, cert_manager, vault, grafana, keycloak, argocd, gitea)
-h | --help                         Usage
EOF
}

# Pre-validation
validate_env_var CLUSTER_OWNER "Cluster owner \$CLUSTER_OWNER not set"

supported_services=("alb" "external_dns" "cert_manager" "vault" "grafana" "keycloak" "argocd" "gitea")

SHORT=p:,c:,n:,s:,h
LONG=provider:,context:,name:,services:,help
OPTS=$(getopt -a -n "provision-integrations.sh" --options $SHORT --longoptions $LONG -- "$@")

VALID_ARGUMENTS=$#

if [ "$VALID_ARGUMENTS" -eq 0 ]; then
  help
fi

eval set -- "$OPTS"

while :
do
  case "$1" in
    -p | --provider )
      cloud_provider="$2"
      shift 2
      ;;
    -c | --context )
      context="$2"
      shift 2
      ;;
    -n | --name )
      cluster_name="$2"
      shift 2
      ;;
    -s | --services )
      services="$2"
      shift 2
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

validate_var $cloud_provider "Cloud provider not specified"
validate_var $context "Kubernetes context not specified"
validate_var $cluster_name "Cluster name not specified"
validate_var $services "Services list not specified"

if [[ $cloud_provider != "aks" && $cloud_provider != "eks" && $cloud_provider != "gke" ]]; then
    error_exit "Only accepted cloud providers are [aks, eks, gke]"
fi

if [[ $cloud_provider == "eks" ]]; then
    validate_env_var EKS_CLUSTER_REGION "EKS cluster region \$EKS_CLUSTER_REGION not set"
elif [[ $cloud_provider == "gke" ]]; then
    validate_env_var GKE_CLUSTER_REGION "GKE cluster region \$GKE_CLUSTER_REGION not set"
fi

for service in $(echo $services | tr "," "\n")
do
    if [[ ! " ${supported_services[*]} " =~ " ${service} " ]]; then
        error_exit "Service ${service} isnt accepted currently"
    fi

    if [[ "${service}" == "alb" ]]; then
        if [[ "${cloud_provider}" == "eks" ]]; then
            install_alb_controller $context $cluster_name
        fi
    elif [[ "${service}" == "external_dns" ]]; then
        if [[ "${cloud_provider}" == "eks" || "${cloud_provider}" == "gke" ]]; then
            install_external_dns $context $cluster_name $cloud_provider
        fi
    elif [[ "${service}" == "cert_manager" ]]; then
        install_cert_manager $context $cluster_name $cloud_provider
    elif [[ "${service}" == "vault" ]]; then
        install_vault $context
    elif [[ "${service}" == "grafana" ]]; then
        install_grafana $context
    elif [[ "${service}" == "keycloak" ]]; then
        install_keycloak $context
    elif [[ "${service}" == "argocd" ]]; then
        install_argocd $context 
    elif [[ "${service}" == "gitea" ]]; then
        install_gitea $context
    else
        error_exit "Service ${service} isnt recognized"
    fi
done
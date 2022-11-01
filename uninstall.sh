#!/bin/bash

###################################################################
# Script Name   : uninstall.sh
# Description   : Clean up tasks and also deprovision the clusters
# Author        : Kasun Talwatta
# Email         : kasun.talwatta@solo.io
###################################################################

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

print_info() {
    echo "============================================================"
    echo "$1"
    echo "============================================================"
    echo ""
}

purge_integration_services() {
    print_info "Purging all the integration services on every cluster"

    helm --kube-context $MGMT_CONTEXT -n vault del vault

    helm --kube-context $WEST_CONTEXT -n cert-manager del cert-manager
    helm --kube-context $EAST_CONTEXT -n cert-manager del cert-manager
    helm --kube-context $MGMT_CONTEXT -n cert-manager del cert-manager

    helm --kube-context $WEST_CONTEXT -n external-dns del external-dns
    
    kubectl --context ${MGMT_CONTEXT} delete ns grafana vault keycloak

    helm --kube-context $WEST_CONTEXT -n kube-system del aws-load-balancer-controller

    # Clean up the Route53 records
    export TOP_LEVEL_HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name --output json --dns-name "$PARENT_DOMAIN_NAME." | jq -r '.HostedZones[0].Id')
    export HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name --output json --dns-name "$DOMAIN_NAME." | jq -r '.HostedZones[0].Id')
    aws route53 list-resource-record-sets \
        --hosted-zone-id $HOSTED_ZONE_ID |
        jq -c '.ResourceRecordSets[]' |
        while read -r resourcerecordset; do
            read -r name type <<<$(echo $(jq -r '.Name,.Type' <<<"$resourcerecordset"))
            if [ $type != "NS" -a $type != "SOA" ]; then
                aws route53 change-resource-record-sets \
                    --hosted-zone-id $HOSTED_ZONE_ID \
                    --change-batch '{"Changes":[
                        {
                            "Action":"DELETE",
                            "ResourceRecordSet":'"$resourcerecordset"'
                        }
                    ]}' \
                    --output text --query 'ChangeInfo.Id'
            fi
        done

    CHANGE_ID=$(aws route53 delete-hosted-zone \
        --id $HOSTED_ZONE_ID \
        --output text --query 'ChangeInfo.Id')
    aws route53 wait resource-record-sets-changed \
        --id "$CHANGE_ID"

    aws route53 list-resource-record-sets \
        --hosted-zone-id $TOP_LEVEL_HOSTED_ZONE_ID |
        jq -c '.ResourceRecordSets[]' |
        while read -r resourcerecordset; do
            read -r name <<<$(echo $(jq -r '.Name' <<<"$resourcerecordset"))
            if [ "$DOMAIN_NAME." = "$name" ]; then
                CHANGE_ID=$(aws route53 change-resource-record-sets \
                    --hosted-zone-id $TOP_LEVEL_HOSTED_ZONE_ID \
                    --change-batch '{"Changes":[
                        {
                            "Action":"DELETE",
                            "ResourceRecordSet":'"$resourcerecordset"'
                        }
                    ]}' \
                    --output text --query 'ChangeInfo.Id')
                aws route53 wait resource-record-sets-changed \
                    --id "$CHANGE_ID"
            fi
        done
}

purge_mesh_services() {
    print_info "Purging all the mesh services on every cluster"

    # Istio
    helm --kube-context $WEST_CONTEXT -n istio-system del istio-base
    helm --kube-context $WEST_CONTEXT -n istio-system del istiod
    helm --kube-context $WEST_CONTEXT -n istio-ingress del istio-ingressgateway
    helm --kube-context $WEST_CONTEXT -n istio-eastwest del istio-eastwestgateway
    kubectl --context $WEST_CONTEXT delete ns istio-eastwest istio-ingress istio-system istio-config

    helm --kube-context $EAST_CONTEXT -n istio-system del istio-base
    helm --kube-context $EAST_CONTEXT -n istio-system del istiod
    helm --kube-context $EAST_CONTEXT -n istio-ingress del istio-ingressgateway
    helm --kube-context $EAST_CONTEXT -n istio-eastwest del istio-eastwestgateway
    kubectl --context $EAST_CONTEXT delete ns istio-eastwest istio-ingress istio-system istio-config

    # Gloo Mesh
    helm --kube-context $WEST_CONTEXT -n gloo-mesh del gloo-mesh-agent
    helm --kube-context $EAST_CONTEXT -n gloo-mesh del gloo-mesh-agent

    helm --kube-context $WEST_CONTEXT -n gloo-mesh-addons del gloo-mesh-agent-addons
    helm --kube-context $EAST_CONTEXT -n gloo-mesh-addons del gloo-mesh-agent-addons

    kubectl --context $WEST_CONTEXT delete ns gloo-mesh gloo-mesh-addons
    kubectl --context $EAST_CONTEXT delete ns gloo-mesh gloo-mesh-addons

    helm --kube-context $MGMT_CONTEXT -n gloo-mesh del gloo-mesh-enterprise
    kubectl --context $MGMT_CONTEXT delete ns gloo-mesh
}

purge_clusters() {
    print_info "Purging all the clusters"

    $DIR/cluster-provision/scripts/provision-gke-cluster.sh delete -n ${EAST_CLUSTER} -o ${CLUSTER_OWNER} -r ${GKE_CLUSTER_REGION}
    $DIR/cluster-provision/scripts/provision-eks-cluster.sh delete -n ${WEST_CLUSTER} -o ${CLUSTER_OWNER} -r ${EKS_CLUSTER_REGION}
    $DIR/cluster-provision/scripts/provision-eks-cluster.sh delete -n ${MGMT_CLUSTER} -o ${CLUSTER_OWNER} -r ${EKS_CLUSTER_REGION}
}

should_purge_clusters=false
should_purge_mesh_services=false
should_purge_integration_services=false

SHORT=c,i,m,h
LONG=cluster,integrations,mesh,help
OPTS=$(getopt -a -n "uninstall.sh" --options $SHORT --longoptions $LONG -- "$@")

eval set -- "$OPTS"

while : 
do
  case "$1" in
    -c | --cluster )
      shift 1
      should_purge_clusters=true
      ;;
    -i | --integrations )
      shift 1
      should_purge_integration_services=true
      ;;
    -m | --mesh )
      shift 1
      should_purge_mesh_services=true
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

if [[ "$should_purge_mesh_services" == true ]]; then
    purge_mesh_services
fi

if [[ "$should_purge_integrations" == true ]]; then
    purge_integration_services
fi

# Finally remove all the clusters if specified
if [[ "$should_purge_clusters" == true ]]; then
    purge_clusters

    rm -rf $DIR/_output
fi
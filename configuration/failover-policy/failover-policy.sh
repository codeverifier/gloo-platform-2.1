#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

Provision() {
    echo "------------------------------------------------------------"
    echo "Injecting failover policies in west cluster"
    echo "Note: This will failover to the next available reviews service"
    echo "in either of the clusters"
    echo "------------------------------------------------------------"
    echo ""

    kubectl --context ${WEST_CONTEXT} apply -f $DIR/ops-team/namespace.yaml
    kubectl --context ${WEST_CONTEXT} apply -f $DIR/web-frontend-team/namespace.yaml
    kubectl --context ${WEST_CONTEXT} apply -f $DIR/backend-apis-team/namespace.yaml

    # ---- Ops team ----
    envsubst < <(cat $DIR/ops-team/ops-team-workspace.yaml) | kubectl --context ${MGMT_CONTEXT} apply -f -
    envsubst < <(cat $DIR/ops-team/web-frontend-team-workspace.yaml) | kubectl --context ${MGMT_CONTEXT} apply -f -
    envsubst < <(cat $DIR/ops-team/backend-apis-team-workspace.yaml) | kubectl --context ${MGMT_CONTEXT} apply -f -
    kubectl --context ${WEST_CONTEXT} apply -f $DIR/ops-team/ops-team-workspace-settings.yaml
    kubectl --context ${MGMT_CONTEXT} apply -f $DIR/ops-team/east-west-gw.yaml
    # Inject GW
    envsubst < <(cat $DIR/ops-team/north-south-gateway-tls-cert.yaml) | kubectl --context ${WEST_CONTEXT} apply -f -
    envsubst < <(cat $DIR/ops-team/north-south-gateway.yaml) | kubectl --context ${WEST_CONTEXT} apply -f -

    # ---- Frontend team ----
    kubectl --context ${WEST_CONTEXT} apply -f $DIR/web-frontend-team/workspace-settings.yaml
    # Inject RT
    envsubst < <(cat $DIR/web-frontend-team/product-route-table.yaml) | kubectl --context ${WEST_CONTEXT} apply -f -

    # ---- Backend team ----
    kubectl --context ${WEST_CONTEXT} apply -f $DIR/backend-apis-team/workspace-settings.yaml
    kubectl --context ${WEST_CONTEXT} apply -f $DIR/backend-apis-team/reviews-route-table.yaml
    envsubst < <(cat $DIR/backend-apis-team/reviews-virtual-destination.yaml) | kubectl --context ${WEST_CONTEXT} apply -f -
    kubectl --context ${WEST_CONTEXT} apply -f $DIR/backend-apis-team/reviews-failover-policy.yaml
}

Delete() {
    echo "Cleaning up ..."

    # ---- Ops team ----
    envsubst < <(cat $DIR/ops-team/ops-team-workspace.yaml) | kubectl --context ${MGMT_CONTEXT} delete -f -
    envsubst < <(cat $DIR/ops-team/web-frontend-team-workspace.yaml) | kubectl --context ${MGMT_CONTEXT} delete -f -
    envsubst < <(cat $DIR/ops-team/backend-apis-team-workspace.yaml) | kubectl --context ${MGMT_CONTEXT} delete -f -
    kubectl --context ${WEST_CONTEXT} delete -f $DIR/ops-team/ops-team-workspace-settings.yaml
    kubectl --context ${MGMT_CONTEXT} delete -f $DIR/ops-team/east-west-gw.yaml
    # Inject GW
    #envsubst < <(cat $DIR/ops-team/north-south-gateway-tls-cert.yaml) | kubectl --context ${WEST_CONTEXT} delete -f -
    envsubst < <(cat $DIR/ops-team/north-south-gateway.yaml) | kubectl --context ${WEST_CONTEXT} delete -f -

    # ---- Frontend team ----
    kubectl --context ${WEST_CONTEXT} delete -f $DIR/web-frontend-team/workspace-settings.yaml
    # Inject RT
    envsubst < <(cat $DIR/web-frontend-team/product-route-table.yaml) | kubectl --context ${WEST_CONTEXT} delete -f -

    # ---- Backend team ----
    kubectl --context ${WEST_CONTEXT} delete -f $DIR/backend-apis-team/workspace-settings.yaml
    kubectl --context ${WEST_CONTEXT} delete -f $DIR/backend-apis-team/reviews-route-table.yaml
    envsubst < <(cat $DIR/backend-apis-team/reviews-virtual-destination.yaml) | kubectl --context ${WEST_CONTEXT} delete -f -
    kubectl --context ${WEST_CONTEXT} delete -f $DIR/backend-apis-team/reviews-failover-policy.yaml
}

SimulateFailOver() {
    echo "Scaling down review services in west-cluster"
    echo ""
    kubectl --context ${WEST_CONTEXT} -n bookinfo-backends scale deploy/reviews-v1 --replicas=0
    kubectl --context ${WEST_CONTEXT} -n bookinfo-backends wait --for=jsonpath='{.spec.replicas}'=0 deploy/reviews-v1

    kubectl --context ${WEST_CONTEXT} -n bookinfo-backends scale deploy/reviews-v2 --replicas=0
    kubectl --context ${WEST_CONTEXT} -n bookinfo-backends wait --for=jsonpath='{.spec.replicas}'=0 deploy/reviews-v2
}

RestoreFailOver() {
    echo "Restoring review services in west-cluster"
    echo ""
    kubectl --context ${WEST_CONTEXT} -n bookinfo-backends scale deploy/reviews-v1 --replicas=1
    kubectl --context ${WEST_CONTEXT} -n bookinfo-backends wait --for=jsonpath='{.spec.replicas}'=1 deploy/reviews-v1

    kubectl --context ${WEST_CONTEXT} -n bookinfo-backends scale deploy/reviews-v2 --replicas=1
    kubectl --context ${WEST_CONTEXT} -n bookinfo-backends wait --for=jsonpath='{.spec.replicas}'=1 deploy/reviews-v2
}

shift $((OPTIND-1))
subcommand=$1; shift
case "$subcommand" in
    prov )
        Provision
    ;;
    del )
        Delete
    ;;
    simfail )
        SimulateFailOver
    ;;
    ressimfail )
        RestoreFailOver
    ;;
    * ) # Invalid subcommand
        if [ ! -z $subcommand ]; then
            echo "Invalid subcommand: $subcommand"
        fi
        exit 1
    ;;
esac
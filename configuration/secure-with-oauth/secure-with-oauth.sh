#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

error_exit() {
    echo "Error: $1"
    exit 1
}

Provision() {
    echo "------------------------------------------------------------"
    echo "Injecting OIDC authentication for bookinfo in west cluster"
    echo "Note: Using Keycloak as IDP"
    echo "------------------------------------------------------------"
    echo ""

    if [[ -f $DIR/../../_output/keycloak_env.sh ]]; then
        source $DIR/../../_output/keycloak_env.sh
    else
        error_exit "Unable to find 'keycloak_env.sh'"
    fi

    if [[ -z $CLIENT_SECRET_BASE64_ENCODED ]]; then
        error_exit "Please provide OIDC secret via environment variable \$CLIENT_SECRET_BASE64_ENCODED"
    fi
    if [[ -z $CLIENT_ID ]]; then
        error_exit "Please provide OIDC client ID via environment variable \$CLIENT_ID"
    fi

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
    envsubst < <(cat $DIR/ops-team/ext-auth-server.yaml) | kubectl --context ${WEST_CONTEXT} apply -f -

    # ---- Frontend team ----
    kubectl --context ${WEST_CONTEXT} apply -f $DIR/web-frontend-team/workspace-settings.yaml
    # Inject RT
    envsubst < <(cat $DIR/web-frontend-team/product-route-table.yaml) | kubectl --context ${WEST_CONTEXT} apply -f -
    envsubst < <(cat $DIR/web-frontend-team/ext-auth-client-secret.yaml) | kubectl --context ${WEST_CONTEXT} apply -f -
    envsubst < <(cat $DIR/web-frontend-team/ext-auth-policy.yaml) | kubectl --context ${WEST_CONTEXT} apply -f -

    # ---- Backend team ----
    kubectl --context ${WEST_CONTEXT} apply -f $DIR/backend-apis-team/workspace-settings.yaml
    kubectl --context ${WEST_CONTEXT} apply -f $DIR/backend-apis-team/reviews-route-table.yaml
    envsubst < <(cat $DIR/backend-apis-team/reviews-virtual-destination.yaml) | kubectl --context ${WEST_CONTEXT} apply -f -
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
    envsubst < <(cat $DIR/ops-team/ext-auth-server.yaml) | kubectl --context ${WEST_CONTEXT} delete -f -

    # ---- Frontend team ----
    kubectl --context ${WEST_CONTEXT} delete -f $DIR/web-frontend-team/workspace-settings.yaml
    # Inject RT
    envsubst < <(cat $DIR/web-frontend-team/product-route-table.yaml) | kubectl --context ${WEST_CONTEXT} delete -f -
    envsubst < <(cat $DIR/web-frontend-team/ext-auth-client-secret.yaml) | kubectl --context ${WEST_CONTEXT} delete -f -
    envsubst < <(cat $DIR/web-frontend-team/ext-auth-policy.yaml) | kubectl --context ${WEST_CONTEXT} delete -f -

    # ---- Backend team ----
    kubectl --context ${WEST_CONTEXT} delete -f $DIR/backend-apis-team/workspace-settings.yaml
    kubectl --context ${WEST_CONTEXT} delete -f $DIR/backend-apis-team/reviews-route-table.yaml
    envsubst < <(cat $DIR/backend-apis-team/reviews-virtual-destination.yaml) | kubectl --context ${WEST_CONTEXT} delete -f -
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
    * ) # Invalid subcommand
        if [ ! -z $subcommand ]; then
            echo "Invalid subcommand: $subcommand"
        fi
        exit 1
    ;;
esac
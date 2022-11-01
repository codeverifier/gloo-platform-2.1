#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

error_exit() {
    echo "Error: $1"
    exit 1
}

Provision() {
    echo "------------------------------------------------------------"
    echo "Applying authN/authZ for Gloo Mesh UI"
    echo "------------------------------------------------------------"
    echo ""

    if [[ -f $DIR/../../_output/keycloak_env.sh ]]; then
        source $DIR/../../_output/keycloak_env.sh
    else
        error_exit "Unable to find 'keycloak_env.sh'"
    fi

    envsubst < <(cat $DIR/dashboard-settings.yaml) | kubectl --context ${MGMT_CONTEXT} apply -f -
    envsubst < <(cat $DIR/dashboard-client-secret.yaml) | kubectl --context ${MGMT_CONTEXT} apply -f -

    kubectl --context ${EAST_CONTEXT} create ns web-frontend-team
    kubectl --context ${EAST_CONTEXT} create ns backend-apis-team

    kubectl --context ${WEST_CONTEXT} apply -f $DIR/rbac-ops1-cluster-role.yaml
    kubectl --context ${EAST_CONTEXT} apply -f $DIR/rbac-ops1-cluster-role.yaml

    kubectl --context ${WEST_CONTEXT} apply -f $DIR/gloo-mesh-rbac-view.yaml
    kubectl --context ${WEST_CONTEXT} apply -f $DIR/rbac-dev1-role.yaml
    kubectl --context ${WEST_CONTEXT} apply -f $DIR/rbac-dev2-role.yaml
    kubectl --context ${EAST_CONTEXT} apply -f $DIR/gloo-mesh-rbac-view.yaml
    kubectl --context ${EAST_CONTEXT} apply -f $DIR/rbac-dev1-role.yaml
    kubectl --context ${EAST_CONTEXT} apply -f $DIR/rbac-dev2-role.yaml
}

Delete() {
    echo "Cleaning up ..."

    envsubst < <(cat $DIR/dashboard-settings.yaml) | kubectl --context ${MGMT_CONTEXT} delete -f -
    envsubst < <(cat $DIR/dashboard-client-secret.yaml) | kubectl --context ${MGMT_CONTEXT} delete -f -

    kubectl --context ${WEST_CONTEXT} delete -f $DIR/rbac-ops1-cluster-role.yaml
    kubectl --context ${EAST_CONTEXT} delete -f $DIR/rbac-ops1-cluster-role.yaml

    kubectl --context ${WEST_CONTEXT} delete -f $DIR/gloo-mesh-rbac-view.yaml
    kubectl --context ${WEST_CONTEXT} delete -f $DIR/rbac-dev1-role.yaml
    kubectl --context ${WEST_CONTEXT} delete -f $DIR/rbac-dev2-role.yaml

    kubectl --context ${EAST_CONTEXT} delete -f $DIR/gloo-mesh-rbac-view.yaml
    kubectl --context ${EAST_CONTEXT} delete -f $DIR/rbac-dev1-role.yaml
    kubectl --context ${EAST_CONTEXT} delete -f $DIR/rbac-dev2-role.yaml

    kubectl --context ${EAST_CONTEXT} delete ns web-frontend-team
    kubectl --context ${EAST_CONTEXT} delete ns backend-apis-team
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
#!/bin/sh

###################################################################
# Script Name	: provision-aks-cluster.sh
# Description	: For managing AKS clusters
# Author       	: Kasun Talwatta
# Email         : kasun.talwatta@solo.io
# Version       : v0.1
###################################################################

set -e
set -o pipefail

_filename="$(basename $BASH_SOURCE)"

# Default values
DEFAULT_AZ_SUBSCRIPTION_ID=$(az account show --query id --output tsv)
DEFAULT_AZ_TENANT_ID=$(az account show --query tenantId --output tsv)
DEFAULT_NODE_NUM="1"
DEFAULT_MACHINE_TYPE="Standard_DS3_v2"
DEFAULT_REGION="australiaeast"

CLUSTER_NAME_SUFFIX=""
CLUSTER_VERSION=""
NODE_NUM=""
OWNER=""
REGION=""

# Check if default project is set
if [[ -z $DEFAULT_AZ_SUBSCRIPTION_ID || -z $DEFAULT_AZ_TENANT_ID ]]; then
    echo "No subscription or tenant found. Have you run `az login` ?"
    exit 1
fi

# Display usage message function
usage() {
    echo "=================="
    echo "Usage:"
    echo "=================="
    echo "$_filename -h                                                                                                 Display this usage message"
    echo ""
    echo "$_filename create -o <arg> -n <arg> [-a <arg> -m <arg> -r <arg> -v <arg>] ................................... Provisioning a AKS cluster"
    echo "\tRequired arguments:"
    echo "\t-n   Name of the cluster (Uses as the suffix for the name)"
    echo "\t-o   Name of the cluster owner (Used as the prefix for the cluster and for tagging)"
    echo "\tOptional arguments:"
    echo "\t-a - Number of nodes (Default 1 if not specified)"
    echo "\t-m   Machine type (Default \"Standard_DS3_v2\" if not specified)"
    echo "\t-r   Region (Default \"australiaeast\" if not specified)"
    echo "\t-v   Kubernetes version"
    echo ""
    echo "$_filename delete -o <arg> -n <arg> [-r <arg>] .............................................................. Deleting a AKS cluster"
    echo "\tRequired arguments:"
    echo "\t-n   Name of the cluster (Uses as the suffix for the name)"
    echo "\t-o   Name of the cluster owner (Used as the prefix for the cluster and for tagging)"
    echo "\tOptional arguments:"
    echo "\t-r   Region (Default \"australiaeast\" if not specified)"
}

# Find default cluster version in region
get_default_cluster_version_in_region() {
    echo $(az aks get-versions -l $1 --query 'orchestrators[?default == `true`].orchestratorVersion' -o tsv)
}

# Utility function to create a cluster
create_cluster() {
    echo "Creating cluster $1-$2 with $6 nodes of type $5 in $4 region"

    az group create \
        --name "$1-$2-rg" \
        --location $4
    az aks create \
        --name "$1-$2" \
        --resource-group "$1-$2-rg" \
        --kubernetes-version $3 \
        --location $4 \
        --node-vm-size $5 \
        --node-count $6 \
        --node-osdisk-size 30
    az aks get-credentials \
        --name "$1-$2" \
        --resource-group "$1-$2-rg" \
        -f ~/.kube/"$1-$2"_config

    echo "Append ~/.kube/"$1-$2"_config path to KUBECONFIG to load the authentication to the cluster"
}

# Utility function to delete a cluster
delete_cluster() {
    echo "Deleting cluster $1-$2"
    az aks delete \
        --name "$1-$2" \
        --resource-group "$1-$2-rg" \
        --yes
    
    az group delete \
        --name "$1-$2-rg" \
        --yes
}

[ $# -eq 0 ] && usage && exit 1

while getopts ":h" opt; do # Go through the options
    case $opt in
        h ) # Help
            usage
            exit 0 # Exit correctly
        ;;
        ? ) # Invalid option
            echo "[ERROR]: Invalid option: -${OPTARG}"
            usage
            exit 1
        ;;
    esac
done
shift $((OPTIND-1))
subcommand=$1; shift
case "$subcommand" in
    create )
        unset OPTIND
        [ $# -eq 0 ] && usage && exit 1
        while getopts ":a:m:n:o:r:v:" opt; do
            case $opt in
                a )
                    NODE_NUM=$OPTARG
                ;;
                m )
                    MACHINE_TYPE=$OPTARG
                ;;
                n )
                    CLUSTER_NAME_SUFFIX=$OPTARG
                ;;
                o )
                    OWNER=$OPTARG
                ;;
                r )
                    REGION=$OPTARG
                ;;
                v )
                    CLUSTER_VERSION=$OPTARG
                ;;
                : ) # Catch no argument provided
                        echo "[ERROR]: option -${OPTARG} requires an argument"
                        usage
                        exit 1
                ;;
                ? ) # Invalid option
                        echo "[ERROR]: Invalid option: -${OPTARG}"
                        usage
                        exit 1
                ;;
            esac
        done

        if [ -z $OWNER ] || [ -z $CLUSTER_NAME_SUFFIX ]; then
            echo "[ERROR]: Both -o and -n are required"
            usage
            exit 1
        fi

        shift $((OPTIND-1))

        NODE_NUM=${NODE_NUM:-$DEFAULT_NODE_NUM}
        REGION=${REGION:-$DEFAULT_REGION}
        DEFAULT_CLUSTER_VERSION=$(get_default_cluster_version_in_region $REGION)
        CLUSTER_VERSION=${CLUSTER_VERSION:-$DEFAULT_CLUSTER_VERSION}
        MACHINE_TYPE=${MACHINE_TYPE:-$DEFAULT_MACHINE_TYPE}

        create_cluster $OWNER $CLUSTER_NAME_SUFFIX $CLUSTER_VERSION $REGION $MACHINE_TYPE $NODE_NUM
    ;;
    delete )
        unset OPTIND
        [ $# -eq 0 ] && usage && exit 1
        while getopts ":n:o:r:" opt; do
            case $opt in
                n )
                    CLUSTER_NAME_SUFFIX=$OPTARG
                ;;
                o )
                    OWNER=$OPTARG
                ;;
                r )
                    REGION=$OPTARG
                ;;
                : ) # Catch no argument provided
                        echo "[ERROR]: option -${OPTARG} requires an argument"
                        usage
                        exit 1
                ;;
                ? ) # Invalid option
                        echo "[ERROR]: Invalid option: -${OPTARG}"
                        usage
                        exit 1
                ;;
            esac
        done

        if [ -z $OWNER ] || [ -z $CLUSTER_NAME_SUFFIX ]; then
            echo "[ERROR]: Both -o and -n are required"
            usage
            exit 1
        fi

        shift $((OPTIND-1))

        REGION=${REGION:-$DEFAULT_REGION}

        delete_cluster $OWNER $CLUSTER_NAME_SUFFIX $REGION
    ;;
    * ) # Invalid subcommand
        if [ ! -z $subcommand ]; then
            echo "Invalid subcommand: $subcommand"
        fi
        usage
        exit 1
    ;;
esac
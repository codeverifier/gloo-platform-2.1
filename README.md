# Gloo Platform Demo - v2.1

Multicloud Gloo Platform demo with version `2.1.0-rc3`.

## Prerequisites

1. Install tools

  | Command   | Version |      Installation      |
  |:----------|:---------------|:-------------|
  | `helm` | latest | `brew install helm` |
  | `istioctl` | `1.14.5` | `asdf install istioctl 1.14.5` |
  | `meshctl` | `2.1.0-rc3` | `curl -sL https://run.solo.io/meshctl/install | GLOO_MESH_VERSION=v2.1.0-rc3 sh -` |
  | Vault | latest | `brew tap hashicorp/tap && brew install hashicorp/tap/vault` |
  | `cfssl` | latest | `brew install cfssl` |
  | `jq` | latest | `brew install jq` |
  | `kustomize` | latest | `brew install kustomize` |
  | `getopt` | latest | `brew install gnu-getopt` |

2. Set up environment variables

  ```
  export PROJECT="demo-gp-2-1"
  export CLUSTER_OWNER="kasunt"
  export EKS_CLUSTER_REGION=ap-southeast-2
  export GKE_CLUSTER_REGION=australia-southeast1

  export PARENT_DOMAIN_NAME="${CLUSTER_OWNER}.fe.gl00.net"
  export DOMAIN_NAME="${PROJECT}.${PARENT_DOMAIN_NAME}"

  export EAST_CLUSTER="${PROJECT}-east-cluster"
  export WEST_CLUSTER="${PROJECT}-west-cluster"
  export MGMT_CLUSTER="${PROJECT}-mgmt-cluster"

  export EAST_CLOUD_PROVIDER="gke"
  export WEST_CLOUD_PROVIDER="eks"
  export MGMT_CLOUD_PROVIDER="eks"

  export EAST_CONTEXT="gke_$(gcloud config get-value project)_${GKE_CLUSTER_REGION}_${CLUSTER_OWNER}-${EAST_CLUSTER}"
  export WEST_CONTEXT="kasun@${CLUSTER_OWNER}-${WEST_CLUSTER}.${EKS_CLUSTER_REGION}.eksctl.io"
  export MGMT_CONTEXT="kasun@${CLUSTER_OWNER}-${MGMT_CLUSTER}.${EKS_CLUSTER_REGION}.eksctl.io"

  export EAST_MESH_NAME="east-mesh"
  export WEST_MESH_NAME="west-mesh"
  export MGMT_MESH_NAME="mgmt-mesh"
  
  export GLOO_MESH_VERSION="2.1.0-rc3"
  export GLOO_MESH_HELM_VERSION="v${GLOO_MESH_VERSION}"

  export ISTIO_VERSION="1.14.5"
  export ISTIO_HELM_VERSION="${ISTIO_VERSION}"
  export ISTIO_SOLO_VERSION="${ISTIO_VERSION}-solo"
  export ISTIO_SOLO_REPO="us-docker.pkg.dev/gloo-mesh/istio-dd73a086ac13"
  export REVISION="1-14-5"

  export CERT_MANAGER_VERSION="v1.8.2"
  export VAULT_VERSION="0.20.1"
  export ARGOCD_VERSION="4.9.16"
  export GITEA_VERSION="5.0.9"
  ```

3. Provision the clusters

  ```
  ./cluster-provision/scripts/provision-gke-cluster.sh create -n $EAST_CLUSTER -o $CLUSTER_OWNER -a 1 -r $GKE_CLUSTER_REGION
  ./cluster-provision/scripts/provision-eks-cluster.sh create -n $WEST_CLUSTER -o $CLUSTER_OWNER -a 3 -v 1.22 -r $EKS_CLUSTER_REGION
  ./cluster-provision/scripts/provision-eks-cluster.sh create -n $MGMT_CLUSTER -o $CLUSTER_OWNER -a 3 -v 1.22 -r $EKS_CLUSTER_REGION
  ```

## Instructions

Deploy all the services (including integrations) with Vault support

```
./install.sh -i -v
```

## Application Demo

### Deployment

```
./apps/apps-deploy.sh prov
```

### Feature Demo

| Feature   |      Command      |  Notes |
|:----------|:-------------|:------|
| Single cluster traffic routing | `./configuration/single-cluster-traffic/single-cluster-traffic.sh prov` |  |
| Cross cluster traffic routing  | `./configuration/cross-cluster-traffic/cross-cluster-traffic.sh prov`   |  |
| Traffic shifting to reviews v3 | `./configuration/cross-cluster-traffic-shift/cross-cluster-traffic-shift.sh prov` | Shifting traffic to reviews v3 on east cluster |
| Failover policy | `./configuration/failover-policy/failover-policy.sh prov` | Failover to reviews v3 on east cluster when none of the reviews services on west cluster are available |
| Secure with OAuth 2.0 | `./configuration/secure-with-oauth/secure-with-oauth.sh prov` | Secure with Google OIDC |


## Clean Up

```
./uninstall.sh -c -i -m
```
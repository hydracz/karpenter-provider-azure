#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: bash $0 <resource-group> <cluster-name> [--adopt-existing]" >&2
  exit 1
fi
RG=$1
CLUSTER_NAME=$2
ADOPT_EXISTING=false
if [[ ${3:-} == --adopt-existing ]]; then
  ADOPT_EXISTING=true
elif [[ $# -eq 3 ]]; then
  echo "Unknown option: $3" >&2
  exit 1
fi
cd "$(git rev-parse --show-toplevel)"
for tool in az jq helm yq node zip kubectl; do command -v "$tool" >/dev/null; done
SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID:-$(az account show --query id --output tsv)}
NAMESPACE=${KARPENTER_NAMESPACE:-kube-system}
REPLICAS=${CONTROLLER_REPLICAS:-1}
[[ "$REPLICAS" =~ ^[1-9][0-9]*$ ]]
TRANSPORT=${DEPLOY_TRANSPORT:-run-command}
[[ "$TRANSPORT" == direct || "$TRANSPORT" == run-command ]]
IDENTITY_NAME=${KARPENTER_IDENTITY_NAME:-id-karpenter-controller}
IMAGE_TAG=${IMAGE_TAG:-v20261011-dev}
if [[ "$IMAGE_TAG" != v20261011-dev && -z ${IMAGE_DIGEST:-} ]]; then
  echo "Set IMAGE_DIGEST when selecting another IMAGE_TAG" >&2
  exit 1
fi
IMAGE_DIGEST=${IMAGE_DIGEST:-sha256:8f60eba2ddbec07f25455ced69a5858eabb029f3e5ed064fab0926a544a95c1f}
[[ "$IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]
az_json() { az "$@" --subscription "$SUBSCRIPTION_ID" --output json; }
aks=$(az_json aks show --resource-group "$RG" --name "$CLUSTER_NAME")
jq -e '(.nodeProvisioningProfile.mode // "Manual") == "Manual" and .oidcIssuerProfile.enabled == true and .securityProfile.workloadIdentity.enabled == true and (.enableRbac != false)' <<< "$aks" >/dev/null || {
  echo "Require self-hosted/manual provisioning, OIDC, Workload Identity and Kubernetes RBAC; no cluster settings changed." >&2
  exit 1
}
node_rg=$(jq -er '.nodeResourceGroup' <<< "$aks")
location=$(jq -er '.location' <<< "$aks")
system_pool=${SYSTEM_POOL:-$(jq -er '[.agentPoolProfiles[] | select(.mode == "System" and .osType == "Linux" and .provisioningState == "Succeeded" and .count > 0)][0].name // empty' <<< "$aks")}
jq -e --arg pool "$system_pool" 'any(.agentPoolProfiles[]; .name == $pool and .mode == "System" and .osType == "Linux" and .count > 0 and .provisioningState == "Succeeded")' <<< "$aks" >/dev/null
subnet=${NODE_SUBNET_ID:-$(jq -r '[.agentPoolProfiles[].vnetSubnetId | select(. != null)] | unique | if length == 1 then .[0] else empty end' <<< "$aks")}
if [[ -z "$subnet" ]]; then
  vnets=$(az_json network vnet list --resource-group "$node_rg")
  subnet=$(jq -er '[.[].subnets[] | select(.name == "aks-subnet")] | if length == 1 then .[0].id else empty end' <<< "$vnets") || {
    echo "Cannot uniquely discover node subnet; set NODE_SUBNET_ID." >&2
    exit 1
  }
fi
vnet=$(az_json network vnet show --ids "${subnet%/subnets/*}")
identity_list=$(az_json identity list --resource-group "$RG")
identity=$(jq -c --arg name "$IDENTITY_NAME" '[.[]|select(.name == $name)][0] // empty' <<< "$identity_list")
if [[ -z "$identity" ]]; then
  identity=$(az_json identity create --resource-group "$RG" --name "$IDENTITY_NAME" --location "$location")
fi
issuer=$(jq -er '.oidcIssuerProfile.issuerUrl' <<< "$aks")
subject="system:serviceaccount:$NAMESPACE:karpenter-sa"
fic_name="karpenter-${CLUSTER_NAME:0:40}"
fics=$(az_json identity federated-credential list --resource-group "$RG" --identity-name "$IDENTITY_NAME")
matching=$(jq --arg issuer "$issuer" --arg subject "$subject" '[.[]|select(.issuer == $issuer and .subject == $subject and .audiences == ["api://AzureADTokenExchange"])] | length' <<< "$fics")
if [[ "$matching" -eq 0 ]]; then
  if jq -e --arg name "$fic_name" 'any(.[]; .name == $name)' <<< "$fics" >/dev/null; then
    echo "Federated credential name is already bound to another issuer/subject." >&2
    exit 1
  fi
  az_json identity federated-credential create --resource-group "$RG" --identity-name "$IDENTITY_NAME" --name "$fic_name" --issuer "$issuer" --subject "$subject" --audiences api://AzureADTokenExchange >/dev/null
fi
principal=$(jq -er '.principalId' <<< "$identity")
scope=$(az_json group show --name "$node_rg" | jq -er '.id')
for role in "Virtual Machine Contributor" "Network Contributor" "Managed Identity Operator"; do
  assignments=$(az_json role assignment list --assignee-object-id "$principal" --scope "$scope" --role "$role")
  if [[ $(jq length <<< "$assignments") -eq 0 ]]; then
    az_json role assignment create --assignee-object-id "$principal" --assignee-principal-type ServicePrincipal --scope "$scope" --role "$role" >/dev/null
  fi
done
directory="$PWD/dist/helm-$CLUSTER_NAME"
mkdir -p "$directory"
umask 077
az aks get-credentials --subscription "$SUBSCRIPTION_ID" --resource-group "$RG" --name "$CLUSTER_NAME" --file "$directory/kubeconfig" --overwrite-existing --output none
ca_certificate=$(kubectl --kubeconfig "$directory/kubeconfig" config view --raw -o json | jq -er '.clusters[0].cluster["certificate-authority-data"] | @base64d | rtrimstr("\n")')
jq -n --argjson aks "$aks" --argjson identity "$identity" --argjson vnet "$vnet" \
  --arg subnet "$subnet" --arg namespace "$NAMESPACE" --arg tag "$IMAGE_TAG" --arg digest "$IMAGE_DIGEST" \
  --arg subscription "$SUBSCRIPTION_ID" --arg pool "$system_pool" --arg ca "$ca_certificate" --argjson adopt "$ADOPT_EXISTING" --argjson replicas "$REPLICAS" '
  {cluster:$aks.name, namespace:$namespace, release:"karpenter", crdRelease:"karpenter-crd", adopt:$adopt,
   caCertificate:$ca,
   endpoint:("https://" + ($aks.privateFqdn // $aks.fqdn)), sshPublicKey:$aks.linuxProfile.ssh.publicKeys[0].keyData,
  values:{replicas:$replicas, nodeSelector:{"kubernetes.azure.com/agentpool":$pool},
     serviceAccount:{create:true,name:"karpenter-sa",annotations:{"azure.workload.identity/client-id":$identity.clientId}},
     podLabels:{"azure.workload.identity/use":"true"}, settings:{computeRecommendationMode:"disabled"},
     controller:{image:{repository:"quay.io/hydracz/karpenter-controller",tag:$tag,digest:$digest},
       resources:{requests:{cpu:"500m",memory:"768Mi"},limits:{cpu:"1",memory:"2Gi"}},env:
       ([{name:"KUBELET_BOOTSTRAP_TOKEN",valueFrom:{secretKeyRef:{name:"karpenter-bootstrap",key:"token"}}},
         {name:"SSH_PUBLIC_KEY",valueFrom:{secretKeyRef:{name:"karpenter-bootstrap",key:"sshPublicKey"}}}] +
        ({CLUSTER_NAME:$aks.name,CLUSTER_ENDPOINT:("https://"+($aks.privateFqdn // $aks.fqdn)),
          NETWORK_PLUGIN:$aks.networkProfile.networkPlugin,NETWORK_PLUGIN_MODE:($aks.networkProfile.networkPluginMode // ""),
          NETWORK_POLICY:($aks.networkProfile.networkPolicy // ""),NETWORK_DATAPLANE:($aks.networkProfile.networkDataplane // ""),
          DNS_SERVICE_IP:$aks.networkProfile.dnsServiceIp,VNET_SUBNET_ID:$subnet,VNET_GUID:($vnet.resourceGuid // ""),
          NODE_IDENTITIES:$aks.identityProfile.kubeletidentity.resourceId,KUBELET_IDENTITY_CLIENT_ID:$aks.identityProfile.kubeletidentity.clientId,
          AZURE_SUBSCRIPTION_ID:$subscription,LOCATION:$aks.location,AZURE_NODE_RESOURCE_GROUP:$aks.nodeResourceGroup,
          ARM_RESOURCE_GROUP:$aks.resourceGroup,PROVISION_MODE:"aksscriptless",USE_SIG:"false",ENABLE_AZURE_SDK_LOGGING:"false"}
          | to_entries | map({name:.key,value:.value})))}}}
  | if (.sshPublicKey | type) != "string" or .sshPublicKey == "" or (.values.controller.env | any(has("value") and .value == null)) then error("Missing required cluster metadata") else . end
' > "$directory/deployment.json"
jq '.values' "$directory/deployment.json" > "$directory/values.json"
helm package charts/karpenter --destination "$directory" >/dev/null
helm package charts/karpenter-crd --destination "$directory" >/dev/null
chart=$(find "$directory" -maxdepth 1 -name 'karpenter-[0-9]*.tgz' | sort | tail -n 1)
crd_chart=$(find "$directory" -maxdepth 1 -name 'karpenter-crd-*.tgz' | sort | tail -n 1)
cp "$chart" "$directory/controller.tgz"
cp "$crd_chart" "$directory/crds.tgz"
helm template karpenter "$directory/controller.tgz" --namespace "$NAMESPACE" -f "$directory/values.json" | yq eval -o=json '.' - | jq -s 'map(select(. != null)|{kind,apiVersion,metadata:{name:.metadata.name,namespace:.metadata.namespace,labels:.metadata.labels}})' > "$directory/controller-resources.json"
helm template karpenter-crd "$directory/crds.tgz" --namespace "$NAMESPACE" | yq eval -o=json '.' - | jq -s 'map(select(. != null)|{kind,apiVersion,metadata:{name:.metadata.name}})' > "$directory/crd-resources.json"
cp hack/deploy/helm-install.sh "$directory/helm-install.sh"
printf '{"command":"bash helm-install.sh"}\n' > "$directory/install-command.json"
if [[ "$TRANSPORT" == direct ]]; then
  export KUBECONFIG="$directory/kubeconfig"
  cd "$directory"
  bash helm-install.sh
else
  command_id=$(AZURE_SUBSCRIPTION_ID="$SUBSCRIPTION_ID" AZURE_RESOURCE_GROUP="$RG" CLUSTER_NAME="$CLUSTER_NAME" \
    node infra/validation/run-command.mjs start "$directory/install-command.json" \
      "$directory/deployment.json" "$directory/values.json" "$directory/controller.tgz" "$directory/crds.tgz" \
      "$directory/controller-resources.json" "$directory/crd-resources.json" "$directory/helm-install.sh")
  printf 'Helm installation command: %s\n' "$command_id"
  AZURE_SUBSCRIPTION_ID="$SUBSCRIPTION_ID" AZURE_RESOURCE_GROUP="$RG" CLUSTER_NAME="$CLUSTER_NAME" \
    node infra/validation/run-command.mjs wait "$command_id"
fi
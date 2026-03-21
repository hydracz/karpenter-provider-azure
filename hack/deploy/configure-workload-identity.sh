#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 || $# -gt 6 ]]; then
  echo "Usage: $0 <cluster-name> <resource-group> <namespace> [service-account-name] [identity-name] [federated-credential-name]"
  echo "Example: $0 my-aks rg-aks kube-system karpenter-sa karpentermsi KARPENTER_FID"
  exit 1
fi

CLUSTER_NAME=$1
RG=$2
KARPENTER_NAMESPACE=$3
KARPENTER_SERVICE_ACCOUNT_NAME=${4:-karpenter-sa}
IDENTITY_NAME=${5:-karpentermsi}
FEDERATED_CREDENTIAL_NAME=${6:-KARPENTER_FID}

for cmd in az jq kubectl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: command '$cmd' is required but not found"
    exit 1
  fi
done

AKS_JSON=$(az aks show --name "$CLUSTER_NAME" --resource-group "$RG" -o json)
OIDC_ISSUER=$(jq -r '.oidcIssuerProfile.issuerUrl // empty' <<< "$AKS_JSON")
WORKLOAD_IDENTITY_ENABLED=$(jq -r '.securityProfile.workloadIdentity.enabled // false' <<< "$AKS_JSON")

if [[ -z "$OIDC_ISSUER" || "$OIDC_ISSUER" == "null" || "$WORKLOAD_IDENTITY_ENABLED" != "true" ]]; then
  echo "Workload Identity is not fully enabled on cluster '$CLUSTER_NAME'."
  echo "Run the following command first, then rerun this script:"
  echo "  az aks update --name $CLUSTER_NAME --resource-group $RG --enable-oidc-issuer --enable-workload-identity"
  exit 1
fi

LOCATION=$(az group show --name "$RG" --query location -o tsv)
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
RG_MC=$(jq -r '.nodeResourceGroup' <<< "$AKS_JSON")
RG_MC_RES=$(az group show --name "$RG_MC" --query id -o tsv)

IDENTITY_JSON=$(az identity show --name "$IDENTITY_NAME" --resource-group "$RG" -o json 2>/dev/null || true)
if [[ -z "$IDENTITY_JSON" ]]; then
  echo "Creating user-assigned managed identity '$IDENTITY_NAME' in resource group '$RG' ..."
  IDENTITY_JSON=$(az identity create --name "$IDENTITY_NAME" --resource-group "$RG" --location "$LOCATION" -o json)
else
  echo "Managed identity '$IDENTITY_NAME' already exists in resource group '$RG'."
fi

CLIENT_ID=$(jq -r '.clientId' <<< "$IDENTITY_JSON")
PRINCIPAL_ID=$(jq -r '.principalId' <<< "$IDENTITY_JSON")

echo "Ensuring service account ${KARPENTER_NAMESPACE}/${KARPENTER_SERVICE_ACCOUNT_NAME} exists and is annotated ..."
kubectl create namespace "$KARPENTER_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl create serviceaccount "$KARPENTER_SERVICE_ACCOUNT_NAME" -n "$KARPENTER_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate serviceaccount "$KARPENTER_SERVICE_ACCOUNT_NAME" -n "$KARPENTER_NAMESPACE" \
  azure.workload.identity/client-id="$CLIENT_ID" --overwrite
kubectl annotate serviceaccount "$KARPENTER_SERVICE_ACCOUNT_NAME" -n "$KARPENTER_NAMESPACE" \
  azure.workload.identity/tenant-id="$TENANT_ID" --overwrite

SUBJECT="system:serviceaccount:${KARPENTER_NAMESPACE}:${KARPENTER_SERVICE_ACCOUNT_NAME}"

EXISTING_FIC=$(az identity federated-credential list --identity-name "$IDENTITY_NAME" --resource-group "$RG" \
  --query "[?name=='$FEDERATED_CREDENTIAL_NAME'] | [0].name" -o tsv)
if [[ -z "$EXISTING_FIC" ]]; then
  echo "Creating federated credential '$FEDERATED_CREDENTIAL_NAME' ..."
  az identity federated-credential create \
    --name "$FEDERATED_CREDENTIAL_NAME" \
    --identity-name "$IDENTITY_NAME" \
    --resource-group "$RG" \
    --issuer "$OIDC_ISSUER" \
    --subject "$SUBJECT" \
    --audience api://AzureADTokenExchange >/dev/null
else
  echo "Federated credential '$FEDERATED_CREDENTIAL_NAME' already exists."
fi

for role in "Virtual Machine Contributor" "Network Contributor" "Managed Identity Operator"; do
  ASSIGNMENT_ID=$(az role assignment list \
    --assignee-object-id "$PRINCIPAL_ID" \
    --scope "$RG_MC_RES" \
    --role "$role" \
    --query '[0].id' -o tsv)

  if [[ -z "$ASSIGNMENT_ID" ]]; then
    echo "Creating role assignment '$role' on node resource group '$RG_MC' ..."
    az role assignment create \
      --assignee-object-id "$PRINCIPAL_ID" \
      --assignee-principal-type ServicePrincipal \
      --scope "$RG_MC_RES" \
      --role "$role" >/dev/null
  else
    echo "Role assignment '$role' already exists on node resource group '$RG_MC'."
  fi
done

echo ""
echo "Workload Identity configuration completed."
echo "Use the following values for deploy scripts:"
echo "  cluster name:        $CLUSTER_NAME"
echo "  resource group:      $RG"
echo "  service account:     $KARPENTER_SERVICE_ACCOUNT_NAME"
echo "  identity name:       $IDENTITY_NAME"
echo "  identity client id:  $CLIENT_ID"
echo "  oidc issuer:         $OIDC_ISSUER"
echo ""
echo "Next step example:"
echo "  ./hack/deploy/configure-values.sh \"$CLUSTER_NAME\" \"$RG\" \"$KARPENTER_SERVICE_ACCOUNT_NAME\" \"$IDENTITY_NAME\" false"

#!/usr/bin/env bash
set -euo pipefail

: "${AZURE_SUBSCRIPTION_ID:?required}"
: "${NODE_RESOURCE_GROUP:?required}"
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <active|deleted> <vm-name> [expected-image-id] [expected-egress-ip] [spot-max-price]" >&2
  exit 1
fi
mode=$1
vm_name=$2

if [[ "$mode" == deleted ]]; then
  resources=$(az resource list --subscription "$AZURE_SUBSCRIPTION_ID" --resource-group "$NODE_RESOURCE_GROUP" --output json)
  count=$(jq --arg name "$vm_name" '[.[] | select(.name == $name or (.name | startswith($name + "/")))] | length' <<< "$resources")
  if [[ "$count" -ne 0 ]]; then
    jq --arg name "$vm_name" '[.[] | select(.name == $name or (.name | startswith($name + "/"))) | {name,type}]' <<< "$resources"
    echo "Resources still present for $vm_name; deletion is not verified" >&2
    exit 1
  fi
  printf 'PASS no VM/NIC/disk/public IP resources remain for %s\n' "$vm_name"
  exit 0
fi
[[ "$mode" == active && $# -ge 4 ]]
expected_image=$3
expected_egress=$4
vm=$(az vm show --subscription "$AZURE_SUBSCRIPTION_ID" --resource-group "$NODE_RESOURCE_GROUP" --name "$vm_name" --output json)
nic=$(az network nic show --subscription "$AZURE_SUBSCRIPTION_ID" --resource-group "$NODE_RESOURCE_GROUP" --name "$vm_name" --output json)
address=$(az network public-ip show --subscription "$AZURE_SUBSCRIPTION_ID" --resource-group "$NODE_RESOURCE_GROUP" --name "$vm_name" --output json)
lbs=$(az network lb list --subscription "$AZURE_SUBSCRIPTION_ID" --resource-group "$NODE_RESOURCE_GROUP" --output json)

jq -e --arg image "$expected_image" '.provisioningState == "Succeeded" and .storageProfile.diskControllerType == "NVMe" and ((.storageProfile.imageReference.id // .storageProfile.imageReference.communityGalleryImageId) == $image)' <<< "$vm" >/dev/null
ip_id=$(jq -er '.id' <<< "$address")
jq -e --arg address "$ip_id" '.networkSecurityGroup.id != null and any(.ipConfigurations[]; .primary == true and .publicIPAddress.id == $address)' <<< "$nic" >/dev/null
jq -e --arg expected "$expected_egress" '.ipAddress == $expected and .sku.name == "Standard" and .publicIPAllocationMethod == "Static"' <<< "$address" >/dev/null
outbound_ids=$(jq '[.[].outboundRules[]?.backendAddressPool.id | ascii_downcase]' <<< "$lbs")
jq -e --argjson outbound "$outbound_ids" '[.ipConfigurations[].loadBalancerBackendAddressPools[]?.id | ascii_downcase] | all(.[]; . as $pool | ($outbound | index($pool)) == null)' <<< "$nic" >/dev/null
if [[ $# -ge 5 ]]; then
  jq -e --argjson price "$5" '.priority == "Spot" and .billingProfile.maxPrice == $price' <<< "$vm" >/dev/null
fi
jq '{name,sku:.hardwareProfile.vmSize,image:.storageProfile.imageReference,diskController:.storageProfile.diskControllerType,diffDisk:.storageProfile.osDisk.diffDiskSettings,priority,billingProfile}' <<< "$vm"
printf 'PASS Azure image/NVMe/public-IP/outbound-pool checks for %s\n' "$vm_name"
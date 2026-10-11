# Node Public IPv4

Set `AKSNodeClass.spec.nodePublicIP.enabled: true` to request one public IPv4 per
node using the upstream API. Omitted, empty, and disabled blocks preserve the
default behavior and hash. Changes apply to replacement nodes, not existing VMs
in place.

```yaml
apiVersion: karpenter.azure.com/v1beta1
kind: AKSNodeClass
metadata:
   name: direct-egress
spec:
   imageFamily: Ubuntu2404
   nodePublicIP:
      enabled: true
```

Upgrade the controller and generated CRDs together before using the new block.
The earlier `spec.enableNodePublicIP` field remains a deprecated compatibility
fallback in all four modes. An explicit `nodePublicIP` block takes precedence,
including `{}` and `{enabled: false}`; the legacy field is ignored in both the
request and hash in that case. Migrating an enabled legacy field to the new block
can change the NodeClass hash, so observe disruption budgets and replacement nodes.

## Mode Behavior

| Provision mode | Implementation |
| --- | --- |
| `aksscriptless` | Create an owned Standard, Regional, static IPv4; attach it to the primary NIC IP configuration. |
| `bootstrappingclient` | Same VM/NIC lifecycle as scriptless. |
| `aksmachineapi` | Use upstream enablement, optional prefix/IP tags, and drift validation; AKS owns creation and deletion. |
| `aksmachineapiheaderbatch` | Same upstream network profile, included in the shared Machine template and batch grouping. |

VM public IP zones follow the selected node zone. The provider requires the
existing cluster NSG before attachment and does not open SSH, kubelet, NodePort,
or other Internet-facing inbound rules. Review subnet and NIC NSGs: public IPs
increase the impact of overly permissive rules. This feature is IPv4-only and
does not accept an existing public IP ID or custom DNS name. VM modes reject
`nodePublicIP.prefixIDs` and `nodePublicIP.ipTags` before creating resources;
these upstream options are supported only by the two Machine API modes.

For a Machine API NodeClass, an optional public IP prefix and routing preference
can be expressed through the upstream configuration:

```yaml
spec:
  nodePublicIP:
    enabled: true
    prefixIDs:
      - /subscriptions/<subscription-id>/resourceGroups/<network-rg>/providers/Microsoft.Network/publicIPPrefixes/<prefix>
    ipTags:
      - {ipTagType: RoutingPreference, tag: Internet}
```

The controller identity requires Network Contributor or equivalent narrowly scoped
public-IP/NIC permissions on the node resource group. Public IP quotas also limit
scale-out; bound NodePool capacity and check regional limits.

Azure rejects a NIC with an instance public IP if it references a backend pool
used by an LB outbound rule (`NicWithPublicIpCannotReferencePoolWithOutboundRule`).
The VM path excludes the AKS outbound pools and any pools explicitly referenced
by outbound rules, including on retries, while retaining eligible inbound pools.
If an inbound service shares the same outbound-rule pool, split those pools in
the load-balancer configuration before using public-IP nodes for that service.

## Egress and Cost

A node public IP is an explicit outbound method, but does not itself remove a NAT
Gateway, a load balancer, or a user-defined route. In particular, an associated
NAT Gateway or a route through an NVA/firewall can take precedence. Verify the
actual external source IP instead of assuming the new address is used.

It may avoid NAT Gateway/LB processing charges for direct traffic. Public IPv4
hours and normal outbound data-transfer charges still apply. More public IPs may
cost more at large node counts; this feature is not a general promise of lower
total cost. Review current regional prices and security requirements.

For a new isolated validation cluster:

1. Use an independent resource group and BYO subnet with no NAT Gateway and no
   forced-tunneling default route. Disable implicit `defaultOutboundAccess` so
   successful Internet access cannot be mistaken for default SNAT.
2. Give the AKS system pool its own public IPs with `--enable-node-public-ip` too.
   Karpenter's NodeClass does not configure the AKS system pool.
3. Use an AKS-supported egress topology. Current AKS documentation restricts
   `outboundType: none` to network-isolated clusters, with its associated bootstrap
   artifact and networking requirements. Do not simply set `none` on an ordinary
   cluster without satisfying those requirements. `userDefinedRouting` has its
   own route validation requirements and is not a free shortcut.
4. If retaining `outboundType: loadBalancer`, node-level direct egress can be
   tested, but the managed LB may still exist and incur resource charges. Do not
   claim a zero-LB deployment in that case.
5. Do not alter the egress mode of an existing production cluster as part of this
   test; changing outbound topology can break current connections.

## Verification

```bash
kubectl get aksnodeclass direct-egress --output yaml
kubectl get nodeclaims --output wide
az network public-ip list --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$NODE_RESOURCE_GROUP" \
  --query '[].{name:name,ip:ipAddress,sku:sku.name,zones:zones,owner:tags}' --output json
az network nic show --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$NODE_RESOURCE_GROUP" --name "$NODE_VM_NAME" \
  --query '{nsg:networkSecurityGroup.id,ips:ipConfigurations[].publicIPAddress.id}' --output json
```

Run a small Pod pinned to the new node and query an approved external IP echo
endpoint. Compare the observed source address with the node's public IP. For
Azure CNI overlay this verifies pod-to-node SNAT and Internet egress together.
Treat non-overlay Pod networking as a separate network configuration requiring
its own egress verification.

Also inspect the subnet's NAT Gateway and route table and the node resource
group's load balancers. The expected evidence is the actual source IP plus the
resource topology, not merely `nodePublicIP.enabled: true` in YAML.

## Cleanup and Failure Handling

The VM path creates a tagged NIC before allocating the IP, so interrupted
provisioning remains discoverable by existing garbage collection. Retries reuse
an owned address. Cleanup deletes the VM, then NIC, then the owned public IP.
The NIC garbage collector also scans orphaned IPs, protecting addresses linked
to live NodeClaims/VMs, existing NICs, other clusters, or other IP configurations.
Authorization, dependency, and delete failures are returned for retry, not hidden.

After deleting a test NodeClaim, wait for Azure LROs and garbage collection, then
verify that both NIC and owned IP are gone. Repeat with an intentionally invalid
VM creation request and confirm that no billable orphan is left behind. Do not
delete arbitrary IPs by name; only provider-owned IPs carry the required owner
and cluster tags.

References: [AKS node public IPs](https://learn.microsoft.com/azure/aks/use-node-public-ips),
[AKS egress types](https://learn.microsoft.com/azure/aks/egress-outboundtype),
[explicit outbound access](https://learn.microsoft.com/azure/virtual-network/ip-services/default-outbound-access),
[public IP pricing](https://azure.microsoft.com/pricing/details/ip-addresses/).
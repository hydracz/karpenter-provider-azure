# Spot Max Price

Set `karpenter.azure.com/spot-max-price` on NodeClaim annotations, normally through
`NodePool.spec.template.metadata.annotations`. The value is the maximum Spot price
in US dollars per VM-hour, not a budget for the whole NodePool.

## Configuration

Merge this fragment into an existing NodePool:

```yaml
spec:
  template:
    metadata:
      annotations:
        karpenter.azure.com/spot-max-price: "0.03"
```

The annotation does not select Spot capacity. Use the normal
`karpenter.sh/capacity-type` requirement to allow Spot, on-demand, or both. The
annotation is read from the NodeClaim, not from AKSNodeClass or the NodePool's
top-level metadata.

## Values and Defaults

| Value | Behavior |
| --- | --- |
| Not set | Preserve upstream defaults: VM requests use `-1`; Machine requests omit `billing`. |
| `-1` | Use the Azure Spot on-demand price ceiling. |
| Finite number greater than or equal to `0` | Set the requested Spot price ceiling. |
| Empty, nonnumeric, NaN, infinity, or another negative number | Reject the Spot launch before creating Azure resources. |

Leading and trailing whitespace is ignored. The Azure service remains authoritative
for price availability and any additional service-side constraints. Setting a low
ceiling does not guarantee that capacity can be allocated.

For an on-demand launch the annotation is ignored, including invalid values. This
preserves mixed Spot/on-demand NodePools. The annotation does not change the
provider's instance-type ranking or implement a price-aware scheduling filter.

## Provisioning Modes

| Mode | Azure request field |
| --- | --- |
| `aksscriptless` | VM `properties.billingProfile.maxPrice` |
| `bootstrappingclient` | VM `properties.billingProfile.maxPrice` |
| `aksmachineapi` | Machine `properties.billing.spotMaxPrice` |
| `aksmachineapiheaderbatch` | Shared Machine template `properties.billing.spotMaxPrice` |

The current Machine API SDK exposes `MachineBillingProfile.SpotMaxPrice`, so the
older fork's unconditional "unsupported" error is no longer needed. The SDK uses
`float32` for Machine prices and `float64` for VM prices. Machine launches reject
values that overflow `float32` or positive values that would round to zero.
Other Machine prices use the SDK's `float32` precision.

Billing is part of the existing batch grouping key. Different effective prices
produce separate batches; the price stays in the shared request template.

## Lifecycle

1. Karpenter creates a NodeClaim from workload and NodePool requirements.
2. The provider selects an instance type and capacity type.
3. For Spot, the provider parses the annotation before resource creation.
4. The provider sends the price in the VM or Machine create request.
5. Existing upstream provisioning, error handling, and cleanup continue unchanged.

The annotation affects new Azure create requests. It does not update the billing
profile of existing nodes in place. Normal NodePool rollout policies still apply.

## Implementation and Verification

- [VM request construction](../pkg/providers/instance/vminstance.go)
- [Machine template construction](../pkg/providers/instance/aksmachineinstancehelpers.go)
- [Cross-mode creation tests](../pkg/cloudprovider/suite_test.go)
- [Batch grouping tests](../pkg/providers/azclient/aksmachinesheaderbatch/batchkey_test.go)
- [Azure Spot pricing](https://learn.microsoft.com/azure/virtual-machines/spot-vms#pricing)

Local tests verify parsing, payloads in all four modes, rejection before VM/NIC/
Machine creation, and batch price isolation. They use fake Azure clients; live
Spot allocation and eviction are not validated by those tests.
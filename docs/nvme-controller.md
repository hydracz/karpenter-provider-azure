# NVMe OS Disk Controllers

NVMe-only VM sizes require the VM OS disk controller to be NVMe. The provider
reads the SKU's `DiskControllerTypes` capability during its existing storage
lookup and sets `storageProfile.diskControllerType` only when NVMe is supported
and SCSI is not. Exact comma-separated token matching avoids treating `NVMeV2`
as `NVMe`. SCSI-only, dual-controller, missing and unknown metadata preserve the
normal Compute default; there is no new NodeClass configuration switch.

This applies to `aksscriptless` and `bootstrappingclient`, official CIG/SIG and
custom Gallery images, and both managed and ephemeral OS disks. The two Machine
API modes continue to delegate disk-controller selection to AKS.

## Configuration

Choose an available NVMe-capable size in the NodePool and an image supporting
that controller. Do not infer regional availability or quota from the example:

```yaml
spec:
  template:
    spec:
      requirements:
        - key: node.kubernetes.io/instance-type
          operator: In
          values: [Standard_D4ds_v6]
```

Controller selection does not replace upstream OS disk sizing, Trusted Launch
capacity reserves, or ephemeral placement decisions. An ephemeral disk placed
on `NvmeDisk` and the VM's NVMe OS disk controller are distinct settings. When
`osDiskSizeGB` is absent, upstream still chooses a per-SKU size/type; explicit
sizes and `osDiskType: Managed` retain their normal meaning.

## Verification

```bash
az vm show --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$NODE_RESOURCE_GROUP" --name "$NODE_VM_NAME" \
  --query '{controller:storageProfile.diskControllerType,osDisk:storageProfile.osDisk}' \
  --output json
```

For an NVMe-only size expect `controller: NVMe`. Verify the chosen image's actual
driver support; declaring a Gallery feature does not install a driver. Existing
unit and cloud-provider regression tests cover capability parsing and VM payloads
without modifying upstream placement or dependency code.
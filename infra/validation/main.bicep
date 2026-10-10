targetScope = 'resourceGroup'

param location string = resourceGroup().location
param clusterName string = 'aks-karpenter-validation'
param nodeResourceGroupName string = 'rg-karpenter-nodes-20261011'
param kubernetesVersion string = '1.35.8'
param systemVMSize string = 'Standard_D2s_v5'
param adminUsername string = 'azureuser'
param sshPublicKey string

var suffix = uniqueString(subscription().id, resourceGroup().id, location, clusterName)
var tags = {
  Purpose: 'karpenter-porting-validation'
  ManagedBy: 'Bicep'
}
var acrPull = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')

resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2026-05-01' = {
  name: 'nsg-karpenter-validation'
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2026-05-01' = {
  name: 'vnet-karpenter-validation'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: ['10.241.0.0/16']
    }
    subnets: [
      {
        name: 'builder'
        properties: {
          addressPrefix: '10.241.1.0/24'
          defaultOutboundAccess: false
          networkSecurityGroup: { id: networkSecurityGroup.id }
        }
      }
    ]
  }
}

resource clusterIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'id-karpenter-validation'
  location: location
  tags: tags
}

resource registry 'Microsoft.ContainerRegistry/registries@2025-11-01' = {
  name: 'acrkarp${suffix}'
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: false
    anonymousPullEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

resource cluster 'Microsoft.ContainerService/managedClusters@2026-07-01' = {
  name: clusterName
  location: location
  tags: tags
  sku: {
    name: 'Base'
    tier: 'Free'
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${clusterIdentity.id}': {}
    }
  }
  properties: {
    kubernetesVersion: kubernetesVersion
    dnsPrefix: 'karp-${suffix}'
    nodeResourceGroup: nodeResourceGroupName
    enableRBAC: true
    linuxProfile: {
      adminUsername: adminUsername
      ssh: {
        publicKeys: [{ keyData: sshPublicKey }]
      }
    }
    agentPoolProfiles: [
      {
        name: 'sys'
        count: 1
        vmSize: systemVMSize
        osType: 'Linux'
        osSKU: 'Ubuntu'
        osDiskSizeGB: 128
        osDiskType: 'Managed'
        type: 'VirtualMachineScaleSets'
        mode: 'System'
        enableAutoScaling: false
        enableNodePublicIP: true
        availabilityZones: ['1']
        maxPods: 30
        nodeTaints: []
      }
    ]
    apiServerAccessProfile: {
      enablePrivateCluster: true
      enablePrivateClusterPublicFQDN: true
    }
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      networkDataplane: 'cilium'
      networkPolicy: 'cilium'
      loadBalancerSku: 'standard'
      outboundType: 'loadBalancer'
      serviceCidr: '10.240.0.0/16'
      dnsServiceIP: '10.240.0.10'
      podCidr: '10.242.0.0/16'
      ipFamilies: ['IPv4']
    }
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: { enabled: true }
    }
    autoUpgradeProfile: {
      upgradeChannel: 'none'
      nodeOSUpgradeChannel: 'None'
    }
  }
}

resource imagePullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, cluster.id, acrPull)
  scope: registry
  properties: {
    roleDefinitionId: acrPull
    principalId: cluster.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
  }
}

output clusterName string = cluster.name
output nodeResourceGroup string = nodeResourceGroupName
output registryName string = registry.name
output registryLoginServer string = registry.properties.loginServer
output virtualNetworkID string = virtualNetwork.id
output builderSubnetID string = '${virtualNetwork.id}/subnets/builder'
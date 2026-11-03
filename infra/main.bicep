targetScope = 'resourceGroup'

@description('Globally unique storage account name: 3-24 lowercase letters and digits.')
param storageAccountName string

@description('Storage region, chosen independently from the Builder app region.')
param location string = resourceGroup().location

param containerName string = 'filevault'

param tags object = {}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  tags: union({ purpose: 'asb-storage-sample', environment: 'devtest' }, tags)
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'None'
    }
  }
}

resource blobs 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {}
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobs
  name: containerName
  properties: { publicAccess: 'None' }
}

output storageAccountId string = storage.id
output containerScope string = container.id
output blobEndpoint string = storage.properties.primaryEndpoints.blob
output storageContainer string = container.name

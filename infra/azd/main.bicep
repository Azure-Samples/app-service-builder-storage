targetScope = 'subscription'

param environmentName string
param location string
param storageLocation string
param resourceGroupName string
param appName string
param storageAccountName string
param ownerId string

@allowed(['create', 'reuse-owned'])
param builderProvisionMode string

param existingPrincipalId string

var tags = {
  'azd-env-name': environmentName
  'filevault-owner': ownerId
}

resource group 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module storage '../main.bicep' = {
  name: 'filevault-storage'
  scope: group
  params: {
    storageAccountName: storageAccountName
    location: storageLocation
    tags: tags
  }
}

// Never replay an empty-properties Builder PUT over a configured app.
module builder './builder-app.bicep' = if (builderProvisionMode == 'create') {
  name: 'filevault-builder'
  scope: group
  params: { name: appName, location: location, tags: tags }
}

module role '../role.bicep' = {
  name: 'filevault-app-role'
  scope: group
  params: {
    storageAccountName: storageAccountName
    principalId: builderProvisionMode == 'create' ? builder!.outputs.principalId : existingPrincipalId
    principalType: 'ServicePrincipal'
  }
  dependsOn: [storage]
}

output AZURE_RESOURCE_GROUP string = group.name
output BUILDER_APP_NAME string = appName
output BUILDER_APP_RESOURCE_ID string = '${group.id}/providers/Microsoft.Web/builderApps/${appName}'
output BUILDER_APP_PRINCIPAL_ID string = builderProvisionMode == 'create' ? builder!.outputs.principalId : existingPrincipalId
output AZURE_STORAGE_ACCOUNT string = storageAccountName
output AZURE_STORAGE_BLOB_ENDPOINT string = storage.outputs.blobEndpoint
output AZURE_STORAGE_CONTAINER string = storage.outputs.storageContainer
output STORAGE_CONTAINER_RESOURCE_ID string = storage.outputs.containerScope
output STORAGE_ROLE_ASSIGNMENT_ID string = role.outputs.roleAssignmentId

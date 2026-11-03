targetScope = 'resourceGroup'

param storageAccountName string
param containerName string = 'filevault'

@description('Managed identity principal/object ID, not its client ID.')
param principalId string

@allowed(['ServicePrincipal', 'User'])
param principalType string = 'ServicePrincipal'

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}
resource blobs 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' existing = {
  parent: storage
  name: 'default'
}
resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' existing = {
  parent: blobs
  name: containerName
}
var contributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
resource assignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(container.id, principalId, contributorRoleId)
  scope: container
  properties: {
    principalId: principalId
    principalType: principalType
    roleDefinitionId: contributorRoleId
  }
}
output roleAssignmentId string = assignment.id

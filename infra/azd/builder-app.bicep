targetScope = 'resourceGroup'

param name string
param location string
param tags object

resource app 'Microsoft.Web/builderApps@2026-09-01-preview' = {
  name: name
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {}
}

output principalId string = app.identity.principalId

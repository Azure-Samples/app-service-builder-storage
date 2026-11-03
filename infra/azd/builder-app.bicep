targetScope = 'resourceGroup'

param name string
@description('Builder region. West US 2 is the public customer region.')
param location string = 'westus2'
param tags object

resource app 'Microsoft.Web/builderApps@2026-09-01-preview' = {
  name: name
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {}
}

output principalId string = app.identity.principalId

const { BlobServiceClient } = require('@azure/storage-blob');
const { DefaultAzureCredential, ManagedIdentityCredential } = require('@azure/identity');

function createContainerClient(env = process.env) {
  const endpoint = env.AZURE_STORAGE_BLOB_ENDPOINT;
  const container = env.AZURE_STORAGE_CONTAINER;
  if (!endpoint || !/^https:\/\/[a-z0-9]{3,24}\.blob\.core\.windows\.net\/?$/.test(endpoint)) {
    throw new Error('AZURE_STORAGE_BLOB_ENDPOINT must be an Azure public-cloud HTTPS account endpoint without credentials.');
  }
  if (!container || !/^[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])$/.test(container) || container.includes('--')) {
    throw new Error('AZURE_STORAGE_CONTAINER must be a valid private container name.');
  }
  const credential = env.APP_ACCESS_MODE === 'local'
    ? new DefaultAzureCredential()
    : new ManagedIdentityCredential(env.AZURE_CLIENT_ID ? { clientId: env.AZURE_CLIENT_ID } : {});
  return new BlobServiceClient(endpoint, credential, {
    retryOptions: { maxTries: 3, tryTimeoutInMs: 15000 },
  }).getContainerClient(container);
}

module.exports = { createContainerClient };

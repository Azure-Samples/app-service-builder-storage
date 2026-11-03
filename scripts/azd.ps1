#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('preprovision', 'postprovision', 'predeploy', 'predown', 'postdown')]
    [string] $Action = 'preprovision',
    [string] $ProjectRoot = (Split-Path $PSScriptRoot -Parent),
    [switch] $LoadOnly
)

$ErrorActionPreference = 'Stop'
$script:ApiVersion = '2026-09-01-preview'
$script:RoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
$script:Root = [IO.Path]::GetFullPath($ProjectRoot)

function Assert-Condition($Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function Get-Input([string] $Name, [string] $Pattern = '', [switch] $Optional) {
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ($Optional -and [string]::IsNullOrWhiteSpace($value)) { return '' }
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($value)) "Set $Name using azd env set before continuing."
    Assert-Condition ($value -notmatch '[\x00-\x1f\x7f]') "Invalid $Name."
    if ($Pattern) { Assert-Condition ($value -cmatch $Pattern) "Invalid $Name." }
    return $value
}

function Get-Hash([string] $Text) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}

function Invoke-Tool([string] $Name, [string[]] $Arguments, [switch] $Interactive) {
    if ($Interactive) {
        & $Name @Arguments | Out-Host
        Assert-Condition ($LASTEXITCODE -eq 0) "$Name failed. Check the selected account and authorize the exact repository; no deployment was started."
        return
    }
    $result = & $Name @Arguments 2>&1
    Assert-Condition ($LASTEXITCODE -eq 0) "$Name failed. Check the requested command's permissions, tool version and account context; raw output is withheld to avoid credential logging."
    return ($result -join "`n")
}

function Invoke-JsonTool([string] $Name, [string[]] $Arguments) {
    $result = Invoke-Tool $Name $Arguments
    try { return ($result | ConvertFrom-Json -AsHashtable) }
    catch { throw "$Name returned invalid JSON; raw output is withheld to avoid credential logging." }
}

function Set-Output([string] $Name, [string] $Value) {
    $null = Invoke-Tool 'azd' @('env', 'set', $Name, $Value, '--environment', $script:Context.Environment)
}

function Get-Context {
    Assert-Condition (-not $env:GH_HOST -or $env:GH_HOST -ieq 'github.com') 'This source path requires github.com; do not authorize a different GitHub host.'
    $guid = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
    $ctx = @{
        Environment = Get-Input 'AZURE_ENV_NAME' '^[a-z][a-z0-9-]{1,31}$'
        Subscription = Get-Input 'AZURE_SUBSCRIPTION_ID' $guid
        Tenant = Get-Input 'AZURE_TENANT_ID' $guid
        Location = Get-Input 'AZURE_LOCATION' '^[a-z0-9]+$'
        StorageLocation = Get-Input 'STORAGE_LOCATION' '^[a-z0-9]+$'
        Repository = Get-Input 'GITHUB_REPOSITORY' '^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}$'
        Branch = Get-Input 'GITHUB_REF_NAME'
        Account = Get-Input 'GITHUB_ACCOUNT' '^[A-Za-z0-9][A-Za-z0-9-]{0,38}$'
        Commit = Get-Input 'GITHUB_SHA' '^[0-9a-fA-F]{40}$' -Optional
        ResourceGroupInput = Get-Input 'AZURE_RESOURCE_GROUP' -Optional
        AppNameInput = Get-Input 'BUILDER_APP_NAME' -Optional
        StorageNameInput = Get-Input 'AZURE_STORAGE_ACCOUNT' -Optional
    }
    Assert-Condition ($ctx.Branch.Length -le 250 -and -not $ctx.Branch.StartsWith('-')) 'Invalid GITHUB_REF_NAME.'
    $ctx.Allowed = @((Get-Input 'BUILDER_ALLOWED_OBJECT_IDS').Split(',') | ForEach-Object {
        $id = $_.Trim().ToLowerInvariant()
        Assert-Condition ($id -match $guid) 'BUILDER_ALLOWED_OBJECT_IDS must contain GUIDs, not emails or tenant-only rules.'
        $id
    } | Sort-Object -Unique)
    Assert-Condition ($ctx.Allowed.Count -ge 1 -and $ctx.Allowed.Count -le 99) 'Supply 1-99 allowed object IDs.'
    $ctx.Directory = Join-Path $script:Root ".azure/$($ctx.Environment)"
    $ctx.StatePath = Join-Path $ctx.Directory 'filevault-builder.json'
    return $ctx
}

function Read-State {
    Assert-Condition (Test-Path -LiteralPath $script:Context.StatePath) 'Environment receipt missing. Run azd provision; do not adopt existing resources.'
    $state = Get-Content -LiteralPath $script:Context.StatePath -Raw | ConvertFrom-Json -AsHashtable
    Assert-Condition ($state.Schema -eq 1 -and $state.Owner -match '^[0-9a-f]{32}$') 'Invalid environment receipt; review it manually.'
    foreach ($key in @('Environment', 'Subscription', 'Tenant', 'Location', 'StorageLocation', 'Repository', 'Branch', 'Account')) {
        Assert-Condition ($state[$key] -ceq $script:Context[$key]) "Environment $key drift; do not retarget this environment."
    }
    foreach ($key in @('ResourceGroup', 'AppName', 'StorageName')) {
        $inputValue = $script:Context["${key}Input"]
        Assert-Condition (-not $inputValue -or $inputValue -ceq $state[$key]) "Generated $key context drift; do not retarget the owned receipt."
    }
    $script:State = $state
}

function Save-State {
    $path = $script:Context.StatePath
    $temp = "$path.$([Guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temp, ($script:State | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    if (-not $IsWindows) {
        [IO.File]::SetUnixFileMode($temp, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
    }
    [IO.File]::Move($temp, $path, $true)
}

function Initialize-State {
    if (Test-Path -LiteralPath $script:Context.StatePath) { Read-State; return }
    $owner = [Guid]::NewGuid().ToString('N')
    $suffix = (Get-Hash "$($script:Context.Subscription):$($script:Context.Environment):$owner").Substring(0, 16)
    $script:State = @{ Schema = 1; Owner = $owner; ResourceGroup = "rg-fv-$($script:Context.Environment)-$($suffix.Substring(0,8))"
        AppName = "fv-$($script:Context.Environment.Substring(0,[Math]::Min(20,$script:Context.Environment.Length)))-$($suffix.Substring(0,8))"
        StorageName = "fv$suffix"; Infrastructure = 'NotProvisioned' }
    foreach ($key in @('Environment', 'Subscription', 'Tenant', 'Location', 'StorageLocation', 'Repository', 'Branch', 'Account')) {
        $script:State[$key] = $script:Context[$key]
    }
    Save-State
}

function Get-GroupPath { return "/subscriptions/$($script:Context.Subscription)/resourceGroups/$($script:State.ResourceGroup)" }
function Get-AppPath { return "$(Get-GroupPath)/providers/Microsoft.Web/builderApps/$($script:State.AppName)" }
function Get-StoragePath { return "$(Get-GroupPath)/providers/Microsoft.Storage/storageAccounts/$($script:State.StorageName)" }
function Get-ContainerPath { return "$(Get-StoragePath)/blobServices/default/containers/filevault" }

function Assert-OperationUrl([string] $Url) {
    $uri = [Uri] (Assert-ArmUrl $Url)
    Assert-Condition ($uri.AbsolutePath.StartsWith("$(Get-AppPath)/operationStatuses/", [StringComparison]::OrdinalIgnoreCase) -and
        $uri.Query -eq "?api-version=$script:ApiVersion") 'Operation URL does not belong to this exact app/API.'
}

function Assert-ArmUrl([string] $Url) {
    $uri = [Uri] $Url
    Assert-Condition ($uri.Scheme -eq 'https' -and $uri.Host -eq 'management.azure.com' -and $uri.Port -eq 443 -and
        -not $uri.UserInfo -and -not $uri.Fragment -and
        $uri.AbsolutePath.StartsWith("/subscriptions/$($script:Context.Subscription)/", [StringComparison]::OrdinalIgnoreCase)) 'Untrusted ARM operation URL.'
    return $uri.AbsoluteUri
}

function Invoke-Arm([string] $Method, [string] $Path, $Body = $null, [hashtable] $ExtraHeaders = @{}, [string] $Version = $script:ApiVersion) {
    $url = if ($Path.StartsWith('https://')) { Assert-ArmUrl $Path } else { Assert-ArmUrl "https://management.azure.com${Path}?api-version=$Version" }
    $token = Invoke-JsonTool 'az' @('account', 'get-access-token', '--subscription', $script:Context.Subscription,
        '--resource', 'https://management.azure.com/', '--output', 'json')
    Assert-Condition (-not [string]::IsNullOrEmpty($token.accessToken)) 'Azure CLI did not provide an ARM session.'
    $headers = @{ Authorization = "Bearer $($token.accessToken)" }
    foreach ($key in $ExtraHeaders.Keys) { $headers[$key] = $ExtraHeaders[$key] }
    $parameters = @{ Uri = $url; Method = $Method; Headers = $headers; TimeoutSec = 30; MaximumRedirection = 0; SkipHttpErrorCheck = $true }
    if ($null -ne $Body) { $parameters.Body = $Body | ConvertTo-Json -Depth 20 -Compress; $parameters.ContentType = 'application/json' }
    try { $response = Invoke-WebRequest @parameters }
    catch { throw 'ARM response unavailable. Keep the pending receipt and reconcile the same intent; do not start an unrelated operation.' }
    $data = if ($response.Content) { $response.Content | ConvertFrom-Json -AsHashtable } else { @{} }
    return @{ Status = [int] $response.StatusCode; Body = $data; Headers = $response.Headers }
}

function Assert-Response($Response, [int[]] $Statuses = @(200)) {
    Assert-Condition ($Response.Status -in $Statuses) "ARM HTTP $($Response.Status). Inspect the exact target/operation and permissions before retry; sensitive response details are withheld."
}

function Read-Resource([string] $Path, [string] $Version = $script:ApiVersion) {
    $result = Invoke-Arm 'GET' $Path -Version $Version
    if ($result.Status -eq 404) { return $null }
    Assert-Response $result
    return $result.Body
}

function Assert-Owned($Resource, [string] $Id) {
    Assert-Condition ($null -ne $Resource -and $Resource.id -ieq $Id -and
        $Resource.tags.'filevault-owner' -ceq $script:State.Owner -and
        $Resource.tags.'azd-env-name' -ceq $script:Context.Environment) 'Unowned or missing resource. This path never adopts an existing resource.'
}

function Assert-Storage($Storage) {
    Assert-Owned $Storage (Get-StoragePath)
    Assert-Condition ($Storage.location -ieq $script:Context.StorageLocation -and $Storage.sku.name -eq 'Standard_LRS' -and
        $Storage.properties.allowSharedKeyAccess -eq $false -and $Storage.properties.allowBlobPublicAccess -eq $false -and
        $Storage.properties.supportsHttpsTrafficOnly -eq $true -and $Storage.properties.minimumTlsVersion -eq 'TLS1_2' -and
        $Storage.properties.publicNetworkAccess -eq 'Enabled' -and $Storage.properties.networkAcls.defaultAction -eq 'Allow' -and
        $Storage.properties.networkAcls.bypass -eq 'None') 'Storage configuration drift. Do not overwrite or relax a firewall to continue.'
}

function Test-Policy($Policy) {
    $p = $Policy.properties
    return ($p.mode -eq 'required' -and $p.primaryBrowserProvider -eq 'entraId' -and $p.entraId.enabled -eq $true -and
        $p.entraId.applicationMode -eq 'managed' -and -not $p.github.enabled -and
        @($p.entraId.emails).Count -eq 0 -and @($p.entraId.emailSuffixes).Count -eq 0 -and
        (@($p.entraId.tenantIds | Sort-Object) -join ',') -ieq $script:Context.Tenant -and
        (@($p.entraId.objectIds | Sort-Object -Unique) -join ',') -ieq ($script:Context.Allowed -join ','))
}

function Get-PolicyHash { return Get-Hash "$($script:Context.Tenant):$($script:Context.Allowed -join ',')" }

function Assert-ToolsAndSource {
    $azdVersion = Invoke-Tool 'azd' @('version')
    Assert-Condition ($azdVersion -match 'azd version (\d+\.\d+\.\d+)' -and [version] $Matches[1] -ge [version] '1.29.0' -and
        [version] $Matches[1] -lt [version] '2.0.0') 'Use azd >=1.29.0,<2.0.0.'
    $builderVersion = (Invoke-Tool 'builder' @('--version')).Trim()
    Assert-Condition ($builderVersion -match '^\d+\.\d+\.\d+$' -and [version] $builderVersion -ge [version] '0.0.2') 'A compatible Builder CLI 0.0.2 or newer is required separately; this hook never upgrades tools.'
    foreach ($contract in @(
        @{ Arguments = @('app', 'source', 'connect', 'github', '--help'); Flags = @('--name', '--repository-id', '--branch', '--root-directory') }
        @{ Arguments = @('source', 'login', 'github', '--help'); Flags = @('--account') }
        @{ Arguments = @('account', 'show', '--help'); Flags = @('--json') }
        @{ Arguments = @('app', 'version', 'show', '--help'); Flags = @('--name', '--json') }
    )) {
        $help = Invoke-Tool 'builder' $contract.Arguments
        foreach ($flag in $contract.Flags) { Assert-Condition ($help.Contains($flag)) "Builder CLI command contract missing $flag; no resource changes were attempted." }
    }
    $azure = Invoke-JsonTool 'az' @('account', 'show', '--subscription', $script:Context.Subscription, '--output', 'json')
    $builder = Invoke-JsonTool 'builder' @('account', 'show', '--json')
    Assert-Condition ($azure.id -ieq $script:Context.Subscription -and $azure.tenantId -ieq $script:Context.Tenant -and
        $builder.tenantId -ieq $script:Context.Tenant -and $azure.user.type -eq 'user' -and
        $azure.user.name -ieq $builder.username) 'Select the same user and tenant in Azure CLI and builder login; subscription context must match.'
    $github = Invoke-JsonTool 'gh' @('api', 'user', '--hostname', 'github.com')
    Assert-Condition ($github.login -ieq $script:Context.Account) 'Select GITHUB_ACCOUNT in gh before continuing.'
    $repo = Invoke-JsonTool 'gh' @('api', "repos/$($script:Context.Repository)", '--hostname', 'github.com')
    Assert-Condition ($repo.full_name -ieq $script:Context.Repository -and $repo.id -gt 0) 'GitHub repository identity did not match.'
    $commit = Invoke-JsonTool 'gh' @('api', "repos/$($script:Context.Repository)/commits/$([Uri]::EscapeDataString($script:Context.Branch))", '--hostname', 'github.com')
    Assert-Condition ($commit.sha -cmatch '^[0-9a-f]{40}$') 'GitHub did not return a full commit.'
    if ($script:Context.Commit) { Assert-Condition ($script:Context.Commit -ieq $commit.sha) 'GITHUB_SHA does not match the pushed branch. Review and update it explicitly.' }
    $manifest = Invoke-JsonTool 'gh' @('api', "repos/$($script:Context.Repository)/contents/builder.yaml?ref=$($commit.sha)", '--hostname', 'github.com')
    Assert-Condition ($manifest.type -eq 'file') 'The pushed GitHub commit needs a regular root builder.yaml.'
    $script:Context.Commit = $commit.sha
    $script:Context.RepositoryId = [string] $repo.id
}

function Assert-Provider {
    $provider = Read-Resource "/subscriptions/$($script:Context.Subscription)/providers/Microsoft.Web" '2021-04-01'
    $type = @($provider.resourceTypes | Where-Object resourceType -eq 'builderApps')
    Assert-Condition ($provider.registrationState -eq 'Registered' -and $type.Count -eq 1 -and
        $script:ApiVersion -in $type[0].apiVersions -and
        $script:Context.Location -in @($type[0].locations | ForEach-Object { $_.Replace(' ', '').ToLowerInvariant() })) 'Builder provider/API/region is unavailable for this subscription. No registration or resource change was attempted.'
}

function Invoke-Preprovision {
    Assert-ToolsAndSource
    Initialize-State
    Assert-Condition ($script:State.Infrastructure -ne 'Deleted') 'This environment was deleted; create a new azd environment.'
    Assert-Condition ($script:State.Configuration -ne 'Pending') 'A configuration response was lost. Reconcile using azd hooks run postprovision, not another infrastructure operation.'
    Assert-Condition (-not $script:State.Intent -or $script:State.Intent.Status -in @('Succeeded', 'Failed', 'Canceled')) 'A deployment is pending. Resume it using azd hooks run predeploy before provisioning.'
    Assert-Provider
    $group = Read-Resource (Get-GroupPath) '2024-03-01'
    if ($group) { Assert-Owned $group (Get-GroupPath) }
    else { Assert-Condition ($script:State.Infrastructure -eq 'NotProvisioned') 'Owned RG disappeared; do not recreate or adopt automatically.' }
    $app = Read-Resource (Get-AppPath)
    $principal = '00000000-0000-0000-0000-000000000000'
    $mode = 'create'
    if ($app) {
        Assert-Owned $app (Get-AppPath)
        Assert-Condition ($app.location -ieq $script:Context.Location -and $app.identity.type -eq 'SystemAssigned' -and
            $app.identity.principalId) 'Builder location/identity drift; review before continuing.'
        $principal = $app.identity.principalId
        if ($script:State.PrincipalId) { Assert-Condition ($principal -eq $script:State.PrincipalId) 'Managed identity changed; do not silently replace its data role.' }
        $mode = 'reuse-owned'
        if ($app.properties.sourceIntegrationState -eq 'Configured') { Assert-Source $app }
    } else { Assert-Condition ($script:State.Infrastructure -eq 'NotProvisioned') 'Owned app disappeared; do not recreate its identity automatically.' }
    $storage = Read-Resource (Get-StoragePath) '2023-05-01'
    if ($storage) {
        Assert-Storage $storage
        $container = Read-Resource (Get-ContainerPath) '2023-05-01'
        if ($container) { Assert-Condition ($container.properties.publicAccess -eq 'None') 'Container access configuration drift.' }
    }
    else { Assert-Condition ($script:State.Infrastructure -eq 'NotProvisioned') 'Owned storage disappeared; do not recreate it automatically.' }
    foreach ($entry in @{
        AZURE_RESOURCE_GROUP = $script:State.ResourceGroup; BUILDER_APP_NAME = $script:State.AppName
        AZURE_STORAGE_ACCOUNT = $script:State.StorageName; FILEVAULT_OWNER_ID = $script:State.Owner
        BUILDER_PROVISION_MODE = $mode; BUILDER_APP_PRINCIPAL_ID = $principal; GITHUB_SHA = $script:Context.Commit
    }.GetEnumerator()) { Set-Output $entry.Key $entry.Value }
}

function Set-DesiredConfiguration($App) {
    $recovering = $script:State.Configuration -eq 'Pending'
    if ($recovering) {
        Assert-Condition ((Get-Input 'FILEVAULT_RECONCILE_CONFIGURATION' -Optional) -ceq $script:State.ConfigurationIntent.Id) 'A configuration response was lost. Review the receipt and set FILEVAULT_RECONCILE_CONFIGURATION to its ConfigurationIntent.Id before exact replay.'
        $currentNames = @($App.properties.versionConfiguration.variables | ForEach-Object name | Sort-Object)
        $intendedNames = @($script:State.ConfigurationIntent.Variables | ForEach-Object name | Sort-Object)
        Assert-Condition (($currentNames -join ',') -ceq ($intendedNames -join ',') -or
            ($currentNames -join ',') -ceq (@($script:State.ConfigurationIntent.PreviousNames) -join ',')) 'Variable names changed during configuration recovery. Human reconciliation is required; names alone do not prove values.'
    }
    if ($script:State.PolicyHash) { Assert-Condition ($script:State.PolicyHash -ceq (Get-PolicyHash)) 'Visitor allowlist changed; review policy and environment explicitly.' }
    $policy = Invoke-Arm 'GET' "$(Get-AppPath)/authConfigs/current"
    Assert-Response $policy @(200, 404)
    if (-not (Test-Policy $policy.Body)) {
        Assert-Condition (-not $script:State.PolicyHash -and
            ($policy.Status -eq 404 -or ($policy.Body.properties.revision -eq 0 -and $policy.Body.properties.mode -eq 'disabled'))) 'Authentication policy drift; preserve the existing policy for human review.'
        $headers = if ($policy.Status -eq 404) { @{ 'If-None-Match' = '*' } } else { @{ 'If-Match' = [string] $policy.Headers['ETag'] } }
        Assert-Condition ($headers['If-None-Match'] -or $headers['If-Match']) 'Authentication ETag missing.'
        $desired = @{ properties = @{ mode = 'required'; primaryBrowserProvider = 'entraId'; entraId = @{
            enabled = $true; applicationMode = 'managed'; tenantIds = @($script:Context.Tenant); objectIds = $script:Context.Allowed } } }
        $saved = Invoke-Arm 'PUT' "$(Get-AppPath)/authConfigs/current" $desired $headers
        Assert-Response $saved
        Assert-Condition (Test-Policy $saved.Body) 'Saved visitor policy did not match the required allowlist.'
    }
    $script:State.PolicyHash = Get-PolicyHash
    Save-State
    $variables = @(
        @{ name = 'APP_ACCESS_MODE'; value = 'builder' }
        @{ name = 'AZURE_STORAGE_BLOB_ENDPOINT'; value = "https://$($script:State.StorageName).blob.core.windows.net/" }
        @{ name = 'AZURE_STORAGE_CONTAINER'; value = 'filevault' }
    )
    $known = @($variables | ForEach-Object name)
    foreach ($item in @($App.properties.versionConfiguration.variables)) {
        Assert-Condition ($item.name -ine 'AZURE_CLIENT_ID') 'User-assigned credential selection is unexpected in this system-identity path.'
        if ($item.name -and $item.name -notin $known) { $variables += @{ name = $item.name } }
    }
    if ($recovering) { $variables = $script:State.ConfigurationIntent.Variables }
    else {
        $script:State.ConfigurationIntent = @{ Id = [Guid]::NewGuid().ToString(); Variables = $variables
            PreviousNames = @($App.properties.versionConfiguration.variables | ForEach-Object name | Sort-Object) }
    }
    $script:State.Configuration = 'Pending'
    Save-State
    $saved = Invoke-Arm 'PATCH' (Get-AppPath) @{ properties = @{ versionConfiguration = @{ variables = $variables } } }
    Assert-Response $saved
    $script:State.Configuration = 'Saved'
    Save-State
}

function Get-OwnedApp {
    $app = Read-Resource (Get-AppPath)
    Assert-Owned $app (Get-AppPath)
    Assert-Condition ($app.identity.type -eq 'SystemAssigned' -and $app.identity.principalId) 'System-assigned identity is missing.'
    if ($script:State.PrincipalId) { Assert-Condition ($app.identity.principalId -eq $script:State.PrincipalId) 'Managed identity changed; preserve the receipt for review.' }
    return $app
}

function Invoke-Postprovision {
    Read-State
    Set-Output 'BUILDER_INFRASTRUCTURE_STATUS' 'Checking'
    Set-Output 'BUILDER_AUTH_STATUS' 'Checking'
    Assert-Owned (Read-Resource (Get-GroupPath) '2024-03-01') (Get-GroupPath)
    Assert-Storage (Read-Resource (Get-StoragePath) '2023-05-01')
    $app = Get-OwnedApp
    $rolePath = Get-Input 'STORAGE_ROLE_ASSIGNMENT_ID'
    Assert-Condition ($rolePath -imatch "^$([Regex]::Escape((Get-ContainerPath)))/providers/Microsoft.Authorization/roleAssignments/[0-9a-f-]{36}$") 'Role output is outside the private container.'
    $role = Read-Resource $rolePath '2022-04-01'
    Assert-Condition ($role.properties.principalId -eq $app.identity.principalId -and
        $role.properties.roleDefinitionId.EndsWith("/$script:RoleId", [StringComparison]::OrdinalIgnoreCase)) 'Container data-role assignment did not match the app identity.'
    $script:State.PrincipalId = $app.identity.principalId
    $script:State.RoleId = $rolePath
    $deployment = Get-CleanupDeployment
    Assert-Condition ($deployment.properties.provisioningState -eq 'Succeeded') 'Infrastructure deployment did not succeed; preserve its receipt and inspect the failed ARM operation.'
    $script:State.ProvisioningDeploymentId = $deployment.id
    $script:State.ProvisioningTemplateHash = $deployment.properties.templateHash
    $script:State.Infrastructure = 'Provisioned'
    Save-State
    Set-Output 'BUILDER_INFRASTRUCTURE_STATUS' 'Provisioned'
    Set-DesiredConfiguration $app
    Set-Output 'BUILDER_AUTH_STATUS' 'SavedAwaitingActivation'
}

function Assert-Source($App) {
    $source = $App.properties.source
    Assert-Condition ($App.properties.sourceIntegrationState -eq 'Configured' -and $source.provider -ieq 'GitHub' -and
        [string] $source.id -eq $script:Context.RepositoryId -and $source.displayName -ieq $script:Context.Repository -and
        $source.reference -ceq $script:Context.Branch -and (-not $source.rootDirectory -or $source.rootDirectory -eq '.') -and
        $source.autoDeploy -ne $true) 'Source/account/branch/root drift or automatic deployment enabled; do not replace the connection.'
}

function Get-RetryDelay($Response) {
    $seconds = 5
    $parsed = 0
    $header = [string] $Response.Headers['Retry-After']
    if ([int]::TryParse($header, [ref] $parsed)) { $seconds = [Math]::Max(1, $parsed) }
    elseif ($header) {
        $when = [DateTimeOffset]::MinValue
        Assert-Condition ([DateTimeOffset]::TryParse($header, [ref] $when)) 'Invalid Retry-After; preserve the operation receipt.'
        $seconds = [Math]::Max(1, [Math]::Ceiling(($when - [DateTimeOffset]::UtcNow).TotalSeconds))
    }
    return $seconds
}

function Wait-Deployment {
    Assert-OperationUrl $script:State.Intent.OperationUrl
    $deadline = [DateTimeOffset]::UtcNow.AddMinutes(20)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $response = Invoke-Arm 'GET' $script:State.Intent.OperationUrl
        $delay = Get-RetryDelay $response
        if ($response.Status -in @(429, 503)) {
            Assert-Condition ([DateTimeOffset]::UtcNow.AddSeconds($delay) -lt $deadline) 'Polling timeout; keep the receipt and resume the existing deployment.'
            Start-Sleep -Seconds $delay
            continue
        }
        Assert-Response $response
        $status = [string] $response.Body.status
        Assert-Condition ($status -in @('NotStarted', 'Running', 'InProgress', 'Accepted', 'Succeeded', 'Failed', 'Canceled')) 'Unknown operation status; preserve the receipt.'
        if ($status -in @('Succeeded', 'Failed', 'Canceled')) {
            $script:State.Intent.Status = $status
            Save-State
            Set-Output 'BUILDER_DEPLOYMENT_STATUS' $status
            Assert-Condition ($status -eq 'Succeeded') "Builder deployment $status. Inspect its saved operation/deployment ID; repair requires an explicit new request."
            return
        }
        Assert-Condition ([DateTimeOffset]::UtcNow.AddSeconds($delay) -lt $deadline) 'Polling timeout; resume the existing deployment.'
        Start-Sleep -Seconds $delay
    }
    throw 'Polling timeout; resume the existing deployment.'
}

function Submit-OrResume {
    Set-Output 'BUILDER_DEPLOYMENT_STATUS' $script:State.Intent.Status
    if (-not $script:State.Intent.OperationUrl) {
        # A lost response replays only the identical, durable deployment intent.
        $null = Get-OwnedApp
        $result = Invoke-Arm 'POST' "$(Get-AppPath)/deploy" @{
            idempotencyKey = $script:State.Intent.RequestId; commitSha = $script:State.Intent.Commit
        }
        Assert-Response $result @(202)
        $url = [string] $result.Headers['Azure-AsyncOperation']
        Assert-OperationUrl $url
        Assert-Condition ($result.Body.deploymentId -and $url) 'Deployment acceptance receipt is incomplete; retain the request ID for reconciliation.'
        $script:State.Intent.OperationUrl = $url
        $script:State.Intent.DeploymentId = $result.Body.deploymentId
        $script:State.Intent.Status = 'Accepted'
        Save-State
        Set-Output 'BUILDER_APP_DEPLOYMENT_ID' $script:State.Intent.DeploymentId
        Set-Output 'BUILDER_DEPLOYMENT_STATUS' 'Accepted'
        $delay = Get-RetryDelay $result
        Assert-Condition ($delay -le 1200) 'Operation retry interval exceeds this wait budget; resume the receipt later.'
        Start-Sleep -Seconds $delay
    }
    Wait-Deployment
}

function Invoke-AnonymousProbe([string] $Url) {
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $handler.UseDefaultCredentials = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    $request = $null
    $response = $null
    try {
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $Url)
        $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        return [int] $response.StatusCode
    } finally {
        if ($response) { $response.Dispose() }
        if ($request) { $request.Dispose() }
        $client.Dispose()
    }
}

function Test-Anonymous([string] $Url) {
    $uri = [Uri] $Url
    Assert-Condition ($uri.Scheme -eq 'https' -and $uri.Port -eq 443 -and -not $uri.UserInfo -and
        $uri.Host.EndsWith('.builderapps.dev') -and -not $uri.Query -and -not $uri.Fragment -and
        $uri.AbsolutePath -in @('', '/')) 'Unexpected runtime origin; do not send authentication or probe it.'
    foreach ($path in @('/', '/api/files')) {
        $status = Invoke-AnonymousProbe ($Url.TrimEnd('/') + $path)
        Assert-Condition ($status -in @(401, 403, 302)) 'Anonymous application access was not denied; stop before any storage mutation.'
    }
}

function Confirm-Readiness {
    $app = Get-OwnedApp
    Assert-Condition ($app.properties.runtime.activeDeploymentId -eq $script:State.Intent.DeploymentId -and
        $app.properties.runtime.activeAppVersionId -and $app.properties.runtime.url) 'The accepted deployment is not the active runtime.'
    $deadline = [DateTimeOffset]::UtcNow.AddMinutes(2)
    do {
        $auth = Invoke-Arm 'GET' "$(Get-AppPath)/authConfigs/current"
        Assert-Response $auth
        Assert-Condition (Test-Policy $auth.Body) 'Visitor authentication drift; do not probe mutating endpoints.'
        if ($auth.Body.properties.revision -ge 1 -and $auth.Body.properties.appliedRevision -eq $auth.Body.properties.revision -and
            $auth.Body.properties.propagationPending -eq $false) { break }
        Assert-Condition ([DateTimeOffset]::UtcNow -lt $deadline) 'Visitor policy propagation is pending. Resume this completed deployment; do not redeploy.'
        Start-Sleep -Seconds 5
    } while ($true)
    $version = Invoke-JsonTool 'builder' @('app', 'version', 'show', '--name', $script:State.AppName,
        $app.properties.runtime.activeAppVersionId, '--subscription', $script:Context.Subscription,
        '--resource-group', $script:State.ResourceGroup, '--json')
    Assert-Condition ($version.status -eq 'ready' -and $version.source.provider -ieq 'github' -and
        $version.source.revision -ieq $script:State.Intent.Commit) 'Active version does not prove the requested GitHub commit.'
    Test-Anonymous $app.properties.runtime.url
    $script:State.Intent.Readiness = 'Protected'
    Save-State
    foreach ($entry in @{
        BUILDER_APP_URL = $app.properties.runtime.url; BUILDER_APP_RESOURCE_ID = Get-AppPath
        BUILDER_APP_VERSION_ID = $app.properties.runtime.activeAppVersionId
        GITHUB_SHA = $script:State.Intent.Commit
        BUILDER_APP_DEPLOYMENT_ID = $script:State.Intent.DeploymentId; BUILDER_SOURCE_STATUS = 'Connected'
        BUILDER_DEPLOYMENT_STATUS = 'Succeeded'; BUILDER_AUTH_STATUS = 'Applied'
        BUILDER_HEALTH_STATUS = 'AwaitingInteractiveVerification'; FILEVAULT_CRUD_STATUS = 'NotRun'
    }.GetEnumerator()) { Set-Output $entry.Key $entry.Value }
    Write-Host "Deployment succeeded: $($app.properties.runtime.url)"
    Write-Host 'Required sign-in is applied. Sign in as an allowed visitor and verify real Blob upload/list/preview/download/delete. RBAC creation and activation health alone do not prove data access.'
    $script:AwaitingVerification = $true
}

function Invoke-Predeploy {
    Read-State
    foreach ($name in @('BUILDER_SOURCE_STATUS', 'BUILDER_DEPLOYMENT_STATUS', 'BUILDER_AUTH_STATUS')) { Set-Output $name 'Checking' }
    Set-Output 'BUILDER_HEALTH_STATUS' 'AwaitingInteractiveVerification'
    Set-Output 'FILEVAULT_CRUD_STATUS' 'NotRun'
    Assert-Condition ($script:State.Infrastructure -eq 'Provisioned' -and $script:State.Configuration -eq 'Saved') 'Run azd provision and resolve configuration first.'
    $app = Get-OwnedApp
    if ($script:State.Intent -and $script:State.Intent.Status -in @('Pending', 'Accepted', 'Running')) {
        $script:Context.RepositoryId = $script:State.RepositoryId
        Assert-Source $app
        Set-Output 'BUILDER_SOURCE_STATUS' 'Connected'
        Assert-Condition ($script:State.PolicyHash -ceq (Get-PolicyHash)) 'Do not change access rules while recovering an accepted deployment.'
        $policy = Invoke-Arm 'GET' "$(Get-AppPath)/authConfigs/current"
        Assert-Response $policy
        Assert-Condition (Test-Policy $policy.Body) 'Authentication drift while recovering a deployment.'
        Submit-OrResume
        Confirm-Readiness
        return
    }
    if ($script:State.Intent.Status -eq 'Succeeded' -and
        ($script:State.Intent.Readiness -ne 'Protected' -or -not $script:Context.Commit -or
            $script:Context.Commit -ieq $script:State.Intent.Commit)) { Confirm-Readiness; return }
    Assert-ToolsAndSource
    Assert-Storage (Read-Resource (Get-StoragePath) '2023-05-01')
    if ($app.properties.sourceIntegrationState -eq 'Configured') { Assert-Source $app }
    Set-DesiredConfiguration $app
    if ($app.properties.sourceIntegrationState -ne 'Configured') {
        Assert-Condition (-not $app.properties.source.id) 'Existing source connection is not ready; reconcile it rather than replacing it.'
        Invoke-Tool 'builder' @('source', 'login', 'github', '--account', $script:Context.Account) -Interactive
        Invoke-Tool 'builder' @('app', 'source', 'connect', 'github', '--name', $script:State.AppName,
            '--subscription', $script:Context.Subscription, '--resource-group', $script:State.ResourceGroup,
            '--repository', $script:Context.Repository, '--repository-id', $script:Context.RepositoryId,
            '--branch', $script:Context.Branch, '--root-directory', '.') -Interactive
        $app = Get-OwnedApp
    }
    Assert-Source $app
    Set-Output 'BUILDER_SOURCE_STATUS' 'Connected'
    $script:State.RepositoryId = $script:Context.RepositoryId
    $script:State.Intent = @{ RequestId = [Guid]::NewGuid().ToString(); Commit = $script:Context.Commit; Status = 'Pending'; Readiness = 'Pending' }
    Save-State
    Set-Output 'GITHUB_SHA' $script:Context.Commit
    Submit-OrResume
    Confirm-Readiness
}

function Get-ExpectedResources {
    $ids = @((Get-GroupPath), (Get-AppPath), (Get-StoragePath), "$(Get-AppPath)/authConfigs/current",
        "$(Get-StoragePath)/blobServices/default", (Get-ContainerPath), $script:State.RoleId)
    foreach ($name in @('filevault-storage', 'filevault-builder', 'filevault-app-role')) {
        $ids += "$(Get-GroupPath)/providers/Microsoft.Resources/deployments/$name"
    }
    return $ids
}

function Get-Collection([string] $Path, [string] $Version) {
    $items = @()
    $next = $Path
    $pages = 0
    do {
        $response = Invoke-Arm 'GET' $next -Version $Version
        Assert-Response $response
        Assert-Condition ($response.Body.ContainsKey('value') -and ++$pages -le 100) 'ARM inventory is incomplete or exceeds the safety budget.'
        $items += @($response.Body.value)
        $next = $response.Body.nextLink
    } while ($next)
    return $items
}

function Assert-DeploymentGraph($Deployment, [int] $Depth = 0) {
    Assert-Condition ($Depth -le 3 -and $Deployment.properties.ContainsKey('outputResources')) 'Deployment inventory cannot be proven complete.'
    $expected = Get-ExpectedResources
    foreach ($resource in $Deployment.properties.outputResources) {
        Assert-Condition ($resource.id -in $expected) 'azd deployment references a foreign resource; cleanup is blocked.'
        if ($resource.id -imatch '/providers/Microsoft.Resources/deployments/') {
            $nested = Read-Resource $resource.id '2022-09-01'
            Assert-Condition ($null -ne $nested) 'Nested deployment inventory is missing; use reviewed manual cleanup.'
            Assert-DeploymentGraph $nested ($Depth + 1)
        }
    }
}

function Get-CleanupDeployment {
    # Match azd 1.29's latest terminal env-tagged/exact-name selection, never its ambiguous name-hint fallback.
    $all = @(Get-Collection "/subscriptions/$($script:Context.Subscription)/providers/Microsoft.Resources/deployments" '2022-09-01')
    $selected = $null
    foreach ($item in ($all | Sort-Object { $_.properties.timestamp } -Descending)) {
        if ($item.properties.provisioningState -notin @('Succeeded', 'Failed')) { continue }
        if (($item.tags.'azd-env-name' -ceq $script:Context.Environment -and -not $item.tags.ContainsKey('azd-layer-name')) -or
            $item.name -ceq $script:Context.Environment) { $selected = $item; break }
    }
    Assert-Condition ($null -ne $selected) 'No unambiguous azd deployment for this environment; cleanup is blocked.'
    $deployment = Read-Resource $selected.id '2022-09-01'
    Assert-Condition ($deployment.properties.parameters.ownerId.value -ceq $script:State.Owner -and
        $deployment.properties.parameters.resourceGroupName.value -ceq $script:State.ResourceGroup -and
        $deployment.properties.parameters.environmentName.value -ceq $script:Context.Environment -and
        $deployment.properties.templateHash) 'Latest azd deployment does not match the owned receipt.'
    Assert-DeploymentGraph $deployment
    return $deployment
}

function Invoke-Predown {
    Read-State
    Assert-Condition (-not $script:State.Intent -or $script:State.Intent.Status -in @('Succeeded', 'Failed', 'Canceled')) 'Deployment outcome is unresolved; reconcile it before cleanup.'
    Assert-Owned (Read-Resource (Get-GroupPath) '2024-03-01') (Get-GroupPath)
    $app = Read-Resource (Get-AppPath)
    if ($app) { Assert-Owned $app (Get-AppPath) }
    $storage = Read-Resource (Get-StoragePath) '2023-05-01'
    if ($storage) { Assert-Owned $storage (Get-StoragePath) }
    Assert-Condition ((Get-Input 'AZURE_RESOURCE_GROUP') -ceq $script:State.ResourceGroup) 'azd resource-group context drift.'
    $deployment = Get-CleanupDeployment
    Assert-Condition ($deployment.id -ieq $script:State.ProvisioningDeploymentId -and
        $deployment.properties.templateHash -ceq $script:State.ProvisioningTemplateHash) 'Latest azd deployment changed. Do not delete from an unverified deployment.'
    $expected = Get-ExpectedResources
    foreach ($resource in @(Get-Collection "$(Get-GroupPath)/resources" '2021-04-01')) {
        Assert-Condition ($resource.id -in $expected) 'Foreign resource found in the environment RG. azd down is blocked; use reviewed manual cleanup.'
    }
    Write-Host "Cleanup scope: $(Get-GroupPath). ALL files in the sample storage account will be deleted."
    Assert-Condition ([Environment]::GetEnvironmentVariable('AZD_NON_INTERACTIVE') -ne 'true' -and -not [Console]::IsInputRedirected) 'Cleanup requires an interactive human terminal; no --force/--purge or automatic confirmation.'
    $typed = Read-Host "Type the exact resource group name to permit azd's normal deletion confirmation"
    Assert-Condition ($typed -ceq $script:State.ResourceGroup) 'Cleanup canceled.'
}

function Invoke-Postdown {
    Read-State
    Assert-Condition (-not (Read-Resource (Get-GroupPath) '2024-03-01')) 'Cleanup has not finished. Preserve receipts and reconcile the existing Azure operation.'
    $script:State.Infrastructure = 'Deleted'
    Save-State
    Write-Host 'Owned RG deletion confirmed. GitHub repositories, external permissions and any separately owned identities were not removed.'
}

function Invoke-Stage {
    $script:Context = Get-Context
    $null = [IO.Directory]::CreateDirectory($script:Context.Directory)
    $lock = [IO.File]::Open((Join-Path $script:Context.Directory 'filevault-builder.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        switch ($Action) {
            preprovision { Invoke-Preprovision }
            postprovision { Invoke-Postprovision }
            predeploy { Invoke-Predeploy }
            predown { Invoke-Predown }
            postdown { Invoke-Postdown }
        }
    } finally { $lock.Dispose() }
}

if (-not $LoadOnly) {
    Invoke-Stage
    if ($script:AwaitingVerification) { exit 3 }
}

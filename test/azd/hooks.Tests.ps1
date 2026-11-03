$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../../scripts/azd.ps1" -LoadOnly

$fixture = Join-Path ([IO.Path]::GetTempPath()) "filevault-hooks-$([Guid]::NewGuid().ToString('N'))"
$null = [IO.Directory]::CreateDirectory($fixture)
$passed = 0

function Reset-Fixture {
    $script:Context = @{
        Environment = 'offline'; Subscription = '11111111-1111-4111-8111-111111111111'
        Tenant = '22222222-2222-4222-8222-222222222222'; Location = 'westus2'; StorageLocation = 'westus2'
        Repository = 'example/filevault'; Branch = 'main'; Account = 'sample-user'; RepositoryId = '12345'
        Commit = 'a' * 40; Allowed = @('33333333-3333-4333-8333-333333333333')
        Directory = $fixture; StatePath = Join-Path $fixture 'receipt.json'
    }
    $script:State = @{ Schema = 1; Owner = 'a' * 32; ResourceGroup = 'rg-fv-offline'; AppName = 'fv-offline'
        StorageName = 'fvoffline'; Infrastructure = 'Provisioned'; Configuration = 'Saved'; RepositoryId = '12345'
        PrincipalId = '44444444-4444-4444-8444-444444444444' }
    foreach ($key in @('Environment', 'Subscription', 'Tenant', 'Location', 'StorageLocation', 'Repository', 'Branch', 'Account')) {
        $script:State[$key] = $script:Context[$key]
    }
    $script:State.RoleId = "$(Get-ContainerPath)/providers/Microsoft.Authorization/roleAssignments/55555555-5555-4555-8555-555555555555"
    $script:State.PolicyHash = Get-PolicyHash
    $script:Calls = @(); $script:Outputs = @{}; $script:Sleeps = @(); $script:WebStatus = 401
    $script:Http = { throw 'Unmocked ARM request: networking is forbidden in this test.' }
    $script:Json = { throw 'Unmocked CLI: external commands are forbidden in this test.' }
    $script:Text = { throw 'Unmocked CLI: external commands are forbidden in this test.' }
    Save-State
}

function Invoke-Arm($Method, $Path, $Body = $null, $ExtraHeaders = @{}, $Version = '') {
    $script:Calls += @{ Method = $Method; Path = $Path; Body = $Body; Headers = $ExtraHeaders }
    return (& $script:Http $Method $Path $Body $ExtraHeaders)
}
function Invoke-JsonTool($Name, $Arguments) { return (& $script:Json $Name $Arguments) }
function Invoke-Tool($Name, $Arguments, [switch] $Interactive) {
    if ($Name -eq 'azd' -and $Arguments[0] -eq 'env' -and $Arguments[1] -eq 'set') {
        $script:Outputs[$Arguments[2]] = $Arguments[3]; return ''
    }
    return (& $script:Text $Name $Arguments)
}
function Invoke-AnonymousProbe { return $script:WebStatus }
function Start-Sleep([int] $Seconds) { $script:Sleeps += $Seconds }
function Expect($Value, $Message = 'Assertion failed') { if (-not $Value) { throw $Message } }
function Rejects([scriptblock] $Body, [string] $Message) {
    try { & $Body } catch { Expect ($_.Exception.Message -like "*$Message*") $_.Exception.Message; return }
    throw "Expected rejection: $Message"
}
function Check([string] $Name, [scriptblock] $Body) {
    Reset-Fixture
    try { & $Body; $script:passed++; Write-Host "PASS $Name" }
    catch { throw "$Name : $($_.Exception.Message)" }
}
function Owned([string] $Id) {
    return @{ id = $Id; tags = @{ 'filevault-owner' = $script:State.Owner; 'azd-env-name' = $script:Context.Environment } }
}
function App {
    $app = Owned (Get-AppPath)
    $app.location = $script:Context.Location
    $app.identity = @{ type = 'SystemAssigned'; principalId = $script:State.PrincipalId }
    $app.properties = @{
        sourceIntegrationState = 'Configured'
        source = @{ provider = 'GitHub'; id = '12345'; displayName = 'example/filevault'; reference = 'main'; rootDirectory = '.'; autoDeploy = $false }
        versionConfiguration = @{ variables = @(@{ name = 'CUSTOM_SETTING' }, @{ name = 'APP_ACCESS_MODE' }) }
        runtime = @{ activeDeploymentId = 'dep_offline'; activeAppVersionId = 'ver_offline'; url = 'https://fv-offline.app.westus2.builderapps.dev' }
    }
    return $app
}
function Storage {
    $s = Owned (Get-StoragePath)
    $s.location = $script:Context.StorageLocation
    $s.sku = @{ name = 'Standard_LRS' }
    $s.properties = @{ allowSharedKeyAccess = $false; allowBlobPublicAccess = $false; supportsHttpsTrafficOnly = $true
        minimumTlsVersion = 'TLS1_2'; publicNetworkAccess = 'Enabled'; networkAcls = @{ defaultAction = 'Allow'; bypass = 'None' } }
    return $s
}
function Provision-Reads {
    $script:Http = {
        param($method, $path)
        Expect ($method -eq 'GET') 'Preprovision may not write ARM resources.'
        if ($path -like '*/providers/Microsoft.Web') { return @{ Status = 200; Body = @{ registrationState = 'Registered'
            resourceTypes = @(@{ resourceType = 'builderApps'; apiVersions = @('2026-09-01-preview'); locations = @('West US 2') }) } } }
        if ($script:Absent) { return @{ Status = 404; Body = @{} } }
        if ($path -eq (Get-GroupPath)) { return @{ Status = 200; Body = Owned (Get-GroupPath) } }
        if ($path -eq (Get-AppPath)) { return @{ Status = 200; Body = App } }
        if ($path -eq (Get-StoragePath)) { return @{ Status = 200; Body = Storage } }
        return @{ Status = 200; Body = @{ properties = @{ publicAccess = 'None' } } }
    }
}
function Policy {
    return @{ properties = @{ mode = 'required'; primaryBrowserProvider = 'entraId'; revision = 1; appliedRevision = 1
        propagationPending = $false; entraId = @{ enabled = $true; applicationMode = 'managed'
            tenantIds = @($script:Context.Tenant); objectIds = @($script:Context.Allowed); emails = @(); emailSuffixes = @() } } }
}
function Intent {
    $script:State.Intent = @{ RequestId = '66666666-6666-4666-8666-666666666666'; Commit = 'a' * 40; Status = 'Pending'; Readiness = 'Pending' }
}
function OperationUrl { return "https://management.azure.com$(Get-AppPath)/operationStatuses/dep_offline?api-version=2026-09-01-preview" }
function Deployment {
    return @{ id = "/subscriptions/$($script:Context.Subscription)/providers/Microsoft.Resources/deployments/offline-123"
        name = 'offline-123'; tags = @{ 'azd-env-name' = 'offline' }; properties = @{
            provisioningState = 'Succeeded'; timestamp = '2026-01-01T00:00:00Z'; templateHash = '1234'
            parameters = @{ ownerId = @{ value = $script:State.Owner }; resourceGroupName = @{ value = $script:State.ResourceGroup }
                environmentName = @{ value = $script:Context.Environment } }
            outputResources = @(@{ id = Get-GroupPath }, @{ id = Get-AppPath }, @{ id = Get-StoragePath }, @{ id = $script:State.RoleId })
        } }
}
function Compatible-Tools {
    $script:Text = {
        param($name, $arguments)
        if ($name -eq 'azd') { return 'azd version 1.29.0 (build)' }
        if ($arguments[0] -eq '--version') { return '0.0.2' }
        return '--name <name> --repository-id <id> --branch <ref> --root-directory <root> --account <login> --json'
    }
    $script:Json = {
        param($name, $arguments)
        switch ($name) {
            az { return @{ id = $script:Context.Subscription; tenantId = $script:Context.Tenant; user = @{ type = 'user'; name = 'user@example.invalid' } } }
            builder { return @{ username = 'user@example.invalid'; tenantId = $script:Context.Tenant } }
            gh {
                if ($arguments[1] -eq 'user') { return @{ login = 'sample-user' } }
                if ($arguments[1] -like '*/commits/*') { return @{ sha = 'a' * 40 } }
                if ($arguments[1] -like '*/contents/*') { return @{ type = 'file' } }
                return @{ id = 12345; full_name = 'example/filevault' }
            }
        }
    }
}

try {
    Check 'customer regions default to West US 2 and internal overrides require explicit admission' {
        $values = @{
            AZURE_ENV_NAME = $script:Context.Environment; AZURE_SUBSCRIPTION_ID = $script:Context.Subscription
            AZURE_TENANT_ID = $script:Context.Tenant; AZURE_LOCATION = $null; STORAGE_LOCATION = $null
            GITHUB_REPOSITORY = $script:Context.Repository; GITHUB_REF_NAME = $script:Context.Branch
            GITHUB_ACCOUNT = $script:Context.Account; BUILDER_ALLOWED_OBJECT_IDS = $script:Context.Allowed[0]
            GITHUB_SHA = $null; AZURE_RESOURCE_GROUP = $null; BUILDER_APP_NAME = $null
            AZURE_STORAGE_ACCOUNT = $null; SAMPLE_INTERNAL_TEST_ALLOW_EASTUS2 = $null; GH_HOST = 'github.com'
        }
        $saved = @{}
        try {
            foreach ($key in $values.Keys) {
                $saved[$key] = [Environment]::GetEnvironmentVariable($key)
                [Environment]::SetEnvironmentVariable($key, $values[$key])
            }
            $ctx = Get-Context
            Expect ($ctx.Location -ceq 'westus2' -and $ctx.StorageLocation -ceq 'westus2')
            $env:STORAGE_LOCATION = 'eastus2'
            Rejects { Get-Context } 'only public customer region'
            $env:AZURE_LOCATION = 'eastus2'; $env:STORAGE_LOCATION = 'eastus2'
            Rejects { Get-Context } 'only public customer region'
            $env:SAMPLE_INTERNAL_TEST_ALLOW_EASTUS2 = 'true'
            $ctx = Get-Context
            Expect ($ctx.Location -ceq 'eastus2' -and $ctx.StorageLocation -ceq 'eastus2')
            $env:STORAGE_LOCATION = 'westus'
            Rejects { Get-Context } 'only public customer region'
            Expect ($script:Calls.Count -eq 0)
        } finally {
            foreach ($key in $saved.Keys) {
                if ($null -eq $saved[$key]) { Remove-Item "Env:$key" -ErrorAction SilentlyContinue }
                else { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
            }
        }
    }
    Check 'up initializes derived parameters before native provision' {
        $manifest = Get-Content "$PSScriptRoot/../../azure.yaml" -Raw
        Expect ($manifest -match 'up:\s*steps:\s*- azd: hooks run preprovision\s*- azd: provision\s*- azd: hooks run predeploy') 'Bootstrap must precede native Bicep parameter resolution.'
        Expect ($manifest -match 'preprovision:\s*shell: pwsh\s*run: ./scripts/azd.ps1 preprovision') 'Direct provision must retain its preflight hook.'
    }
    Check 'parser has no errors' {
        $tokens = $null; $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/../../scripts/azd.ps1", [ref] $tokens, [ref] $errors)
        Expect ($errors.Count -eq 0)
    }
    Check 'receipt is durable and refuses subscription drift' {
        Read-State
        Expect ($script:State.Owner -ceq ('a' * 32))
        $script:Context.Subscription = '99999999-9999-4999-8999-999999999999'
        Rejects { Read-State } 'Subscription drift'
    }
    Check 'generated resource context cannot be retargeted' {
        $script:Context.ResourceGroupInput = 'rg-unrelated'
        Rejects { Read-State } 'context drift'
    }
    Check 'unowned resources and changed principals cannot be adopted' {
        $app = App; $app.tags.'filevault-owner' = 'other'
        Rejects { Assert-Owned $app (Get-AppPath) } 'Unowned'
        $script:Http = { $a = App; $a.identity.principalId = 'other'; @{ Status = 200; Body = $a } }
        Rejects { Get-OwnedApp } 'identity changed'
    }
    Check 'ARM operation URL rejects foreign hosts, subscriptions and credentials' {
        foreach ($url in @('https://evil.invalid/', 'http://management.azure.com/', 'https://management.azure.com.evil.invalid/',
            'https://user@management.azure.com/subscriptions/x/', 'https://management.azure.com/subscriptions/other/op')) {
            Rejects { Assert-ArmUrl $url } 'Untrusted'
        }
        Expect ((Assert-ArmUrl (OperationUrl)) -eq (OperationUrl))
        Rejects { Assert-OperationUrl ((OperationUrl).Replace('/fv-offline/', '/different-app/')) } 'exact app'
    }
    Check 'incompatible Builder CLI stops before any Azure request' {
        Compatible-Tools
        $script:Text = { param($name) if ($name -eq 'azd') { return 'azd version 1.29.0' }; return '0.0.1' }
        Rejects { Invoke-Preprovision } '0.0.2'
        Expect ($script:Calls.Count -eq 0)
    }
    Check 'compatible tools and exact pushed GitHub source pass preflight' {
        Compatible-Tools
        Assert-ToolsAndSource
        Expect ($script:Context.RepositoryId -eq '12345' -and $script:Context.Commit -eq ('a' * 40))
    }
    Check 'reprovision reuses owned app and principal without a Builder PUT' {
        Compatible-Tools; Provision-Reads; $script:Absent = $false
        Invoke-Preprovision
        Expect ($script:Outputs.BUILDER_PROVISION_MODE -eq 'reuse-owned')
        Expect ($script:Outputs.BUILDER_APP_PRINCIPAL_ID -eq $script:State.PrincipalId)
        Expect (@($script:Calls | Where-Object Method -ne 'GET').Count -eq 0)
    }
    Check 'first provisioning selects create mode only when all named resources are absent' {
        Compatible-Tools; Provision-Reads; $script:Absent = $true
        $script:State.Infrastructure = 'NotProvisioned'; Save-State
        Invoke-Preprovision
        Expect ($script:Outputs.BUILDER_PROVISION_MODE -eq 'create')
        Expect ($script:Outputs.BUILDER_APP_PRINCIPAL_ID -eq '00000000-0000-0000-0000-000000000000')
    }
    Check 'unowned name collision stops before any infrastructure mutation' {
        Compatible-Tools
        $script:Http = {
            param($method, $path)
            if ($path -like '*/providers/Microsoft.Web') { return @{ Status = 200; Body = @{ registrationState = 'Registered'
                resourceTypes = @(@{ resourceType = 'builderApps'; apiVersions = @('2026-09-01-preview'); locations = @('West US 2') }) } } }
            $foreign = Owned (Get-GroupPath); $foreign.tags.'filevault-owner' = 'foreign'
            return @{ Status = 200; Body = $foreign }
        }
        Rejects { Invoke-Preprovision } 'Unowned'
        Expect (@($script:Calls | Where-Object Method -ne 'GET').Count -eq 0)
    }
    Check 'firewall and public-access drift cannot be overwritten' {
        $s = Storage; $s.properties.networkAcls.defaultAction = 'Deny'
        Rejects { Assert-Storage $s } 'firewall'
        $s = Storage; $s.properties.allowBlobPublicAccess = $true
        Rejects { Assert-Storage $s } 'configuration drift'
    }
    Check 'stale requested SHA and mixed management tenants fail preflight' {
        Compatible-Tools
        $script:Context.Commit = 'b' * 40
        Rejects { Assert-ToolsAndSource } 'does not match'
        $script:Context.Commit = 'a' * 40
        $script:Context.Tenant = '99999999-9999-4999-8999-999999999999'
        $script:Json = {
            param($name)
            if ($name -eq 'az') { return @{ id = $script:Context.Subscription; tenantId = $script:Context.Tenant; user = @{ type = 'user'; name = 'user@example.invalid' } } }
            return @{ username = 'user@example.invalid'; tenantId = 'different' }
        }
        Rejects { Assert-ToolsAndSource } 'same user and tenant'
    }
    Check 'policy requires tenant and exact nonempty visitor allowlist' {
        Expect (Test-Policy (Policy))
        $policy = Policy; $policy.properties.entraId.objectIds = @()
        Expect (-not (Test-Policy $policy))
        $policy = Policy; $policy.properties.entraId.emailSuffixes = @('example.invalid')
        Expect (-not (Test-Policy $policy))
        $policy = Policy; $policy.properties.github = @{ enabled = $true }
        Expect (-not (Test-Policy $policy))
    }
    Check 'sparse settings preserve unknown names without reading values' {
        $script:Http = {
            param($method, $path, $body)
            if ($method -eq 'GET') { return @{ Status = 200; Body = Policy } }
            Expect ($method -eq 'PATCH')
            Expect (($body.properties.Keys -join ',') -eq 'versionConfiguration')
            $vars = $body.properties.versionConfiguration.variables
            Expect ($vars.Count -eq 4)
            Expect (-not ($vars | Where-Object name -eq 'CUSTOM_SETTING').ContainsKey('value'))
            Expect (($vars | Where-Object name -eq 'APP_ACCESS_MODE').value -eq 'builder')
            Expect (-not ($vars | Where-Object name -eq 'AZURE_CLIENT_ID'))
            return @{ Status = 200; Body = @{} }
        }
        Set-DesiredConfiguration (App)
        Expect ($script:State.Configuration -eq 'Saved')
    }
    Check 'lost configuration response is not guessed from variable names' {
        $script:Http = {
            param($method)
            if ($method -eq 'GET') { return @{ Status = 200; Body = Policy } }
            throw 'Lost response'
        }
        Rejects { Set-DesiredConfiguration (App) } 'Lost response'
        Read-State
        Expect ($script:State.Configuration -eq 'Pending')
        Rejects { Set-DesiredConfiguration (App) } 'configuration response was lost'
    }
    Check 'explicit configuration recovery replays saved values, not name-based success' {
        $before = [Environment]::GetEnvironmentVariable('FILEVAULT_RECONCILE_CONFIGURATION')
        try {
            $script:State.Configuration = 'Pending'
            $script:State.ConfigurationIntent = @{ Id = 'approved-intent'; Variables = @(
                @{ name = 'CUSTOM_SETTING' }, @{ name = 'APP_ACCESS_MODE'; value = 'builder' }
            ); PreviousNames = @('APP_ACCESS_MODE', 'CUSTOM_SETTING') }
            [Environment]::SetEnvironmentVariable('FILEVAULT_RECONCILE_CONFIGURATION', 'approved-intent')
            $script:Http = { param($method, $path, $body)
                if ($method -eq 'GET') { return @{ Status = 200; Body = Policy } }
                Expect ($body.properties.versionConfiguration.variables.Count -eq 2)
                return @{ Status = 200; Body = @{} }
            }
            Set-DesiredConfiguration (App)
            Expect ($script:State.Configuration -eq 'Saved')
            Expect (@($script:Calls | Where-Object Method -eq 'PATCH').Count -eq 1)
            $script:State.Configuration = 'Pending'
            $app = App; $app.properties.versionConfiguration.variables += @{ name = 'OTHER_WRITER' }
            Rejects { Set-DesiredConfiguration $app } 'names changed'
        } finally { [Environment]::SetEnvironmentVariable('FILEVAULT_RECONCILE_CONFIGURATION', $before) }
    }
    Check 'untouched disabled revision zero policy requires its ETag' {
        $script:State.Remove('PolicyHash')
        $script:Http = { param($method, $path, $body, $headers)
            if ($method -eq 'GET') { return @{ Status = 200; Headers = @{ ETag = '"zero"' }; Body = @{ properties = @{ revision = 0; mode = 'disabled' } } } }
            if ($method -eq 'PUT') { Expect ($headers['If-Match'] -eq '"zero"'); return @{ Status = 200; Body = Policy } }
            return @{ Status = 200; Body = @{} }
        }
        Set-DesiredConfiguration (App)
    }
    Check 'new policy uses create precondition and protects against drift' {
        $script:State.Remove('PolicyHash')
        $script:Http = {
            param($method, $path, $body, $headers)
            if ($method -eq 'GET') { return @{ Status = 404; Body = @{} } }
            if ($method -eq 'PUT') {
                Expect ($headers['If-None-Match'] -eq '*')
                return @{ Status = 200; Body = Policy }
            }
            return @{ Status = 200; Body = @{} }
        }
        Set-DesiredConfiguration (App)
        $script:Http = { $p = Policy; $p.properties.entraId.objectIds = @(); @{ Status = 200; Body = $p } }
        Rejects { Set-DesiredConfiguration (App) } 'policy drift'
    }
    Check 'saved variable AZURE_CLIENT_ID is rejected' {
        $a = App; $a.properties.versionConfiguration.variables += @{ name = 'AZURE_CLIENT_ID' }
        $script:Http = { @{ Status = 200; Body = Policy } }
        Rejects { Set-DesiredConfiguration $a } 'User-assigned'
    }
    Check 'repository branch root and automatic-deploy drift are rejected' {
        foreach ($key in @('id', 'reference', 'rootDirectory', 'autoDeploy')) {
            $a = App
            $a.properties.source[$key] = if ($key -eq 'autoDeploy') { $true } else { 'different' }
            Rejects { Assert-Source $a } 'drift'
        }
    }
    Check 'lost deploy response reuses the exact persisted request and SHA' {
        Intent; Save-State
        $script:Attempt = 0
        $script:Http = {
            param($method, $path, $body)
            if ($method -eq 'POST') {
                $script:Attempt++
                Expect ($body.idempotencyKey -eq '66666666-6666-4666-8666-666666666666')
                Expect ($body.commitSha -eq ('a' * 40) -and $body.Count -eq 2)
                if ($script:Attempt -eq 1) { throw 'Lost response' }
                return @{ Status = 202; Body = @{ deploymentId = 'dep_offline' }; Headers = @{ 'Azure-AsyncOperation' = OperationUrl; 'Retry-After' = '2' } }
            }
            if ($path -like '*operationStatuses*') { return @{ Status = 200; Body = @{ status = 'Succeeded' }; Headers = @{} } }
            return @{ Status = 200; Body = App }
        }
        Rejects { Submit-OrResume } 'Lost response'
        Read-State
        Expect ($script:State.Intent.Status -eq 'Pending')
        Expect ($script:Outputs.BUILDER_DEPLOYMENT_STATUS -eq 'Pending')
        Submit-OrResume
        Expect ($script:State.Intent.Status -eq 'Succeeded' -and $script:Attempt -eq 2)
        Expect (2 -in $script:Sleeps)
    }
    Check 'accepted operation resumes without another POST and respects throttling' {
        Intent
        $script:State.Intent.OperationUrl = OperationUrl
        $script:Polls = 0
        $script:Http = {
            param($method)
            Expect ($method -eq 'GET')
            $script:Polls++
            if ($script:Polls -eq 1) { return @{ Status = 429; Headers = @{ 'Retry-After' = '7' } } }
            return @{ Status = 200; Body = @{ status = 'Succeeded' }; Headers = @{} }
        }
        Submit-OrResume
        Expect ($script:Polls -eq 2 -and 7 -in $script:Sleeps)
    }
    Check 'Retry-After dates are respected, malformed values are rejected' {
        $date = [DateTimeOffset]::UtcNow.AddSeconds(90).ToString('r')
        Expect ((Get-RetryDelay @{ Headers = @{ 'Retry-After' = $date } }) -ge 89)
        Rejects { Get-RetryDelay @{ Headers = @{ 'Retry-After' = 'unknown' } } } 'Invalid Retry-After'
    }
    Check 'terminal failure is retained, not converted to ready' {
        Intent; $script:State.Intent.OperationUrl = OperationUrl
        $script:Http = { @{ Status = 200; Body = @{ status = 'Failed' }; Headers = @{} } }
        Rejects { Submit-OrResume } 'Failed'
        Read-State; Expect ($script:State.Intent.Status -eq 'Failed')
        Expect ($script:Outputs.BUILDER_DEPLOYMENT_STATUS -eq 'Failed')
    }
    Check 'HTTP 401 proves protection, never Blob readiness' {
        foreach ($status in @(401, 403, 302)) {
            $script:WebStatus = $status
            Test-Anonymous 'https://fv-offline.app.westus2.builderapps.dev'
        }
        $script:WebStatus = 200
        Rejects { Test-Anonymous 'https://fv-offline.app.westus2.builderapps.dev' } 'not denied'
        Rejects { Test-Anonymous 'https://evil.invalid' } 'runtime origin'
    }
    Check 'readiness outputs retain the deployed SHA and interactive qualification boundary' {
        Intent; $script:State.Intent.DeploymentId = 'dep_offline'; $script:State.Intent.Status = 'Succeeded'
        $script:Context.Commit = 'b' * 40
        $script:Http = { param($method, $path)
            if ($path -like '*authConfigs*') { return @{ Status = 200; Body = Policy } }
            return @{ Status = 200; Body = App }
        }
        $script:Json = { @{ status = 'ready'; source = @{ provider = 'github'; revision = 'a' * 40 } } }
        Confirm-Readiness
        Expect ($script:Outputs.GITHUB_SHA -eq ('a' * 40))
        Expect ($script:Outputs.BUILDER_HEALTH_STATUS -eq 'AwaitingInteractiveVerification')
        Expect ($script:Outputs.FILEVAULT_CRUD_STATUS -eq 'NotRun')
        Expect ($script:AwaitingVerification)
    }
    Check 'same completed SHA re-observes readiness without source/config/deployment writes' {
        Intent
        $script:State.Intent.Status = 'Succeeded'; $script:State.Intent.Readiness = 'Protected'
        $script:State.Intent.DeploymentId = 'dep_offline'; Save-State
        $script:Http = { param($method, $path)
            Expect ($method -eq 'GET')
            if ($path -like '*authConfigs*') { return @{ Status = 200; Body = Policy } }
            return @{ Status = 200; Body = App }
        }
        $script:Json = { @{ status = 'ready'; source = @{ provider = 'github'; revision = 'a' * 40 } } }
        Invoke-Predeploy
        Expect ($script:Calls.Count -gt 1)
        Expect (@($script:Calls | Where-Object Method -ne 'GET').Count -eq 0)
    }
    Check 'latest native cleanup deployment must match ownership parameters' {
        $script:Http = {
            param($method, $path)
            if ($path -match '/deployments$') { return @{ Status = 200; Body = @{ value = @(Deployment) } } }
            return @{ Status = 200; Body = Deployment }
        }
        Expect ((Get-CleanupDeployment).id -like '*offline-123')
        $script:State.Owner = 'b' * 32
        # A foreign parameter, not only a foreign tag, must fail.
        $script:Http = {
            param($method, $path)
            $d = Deployment; $d.properties.parameters.ownerId.value = 'a' * 32
            if ($path -match '/deployments$') { return @{ Status = 200; Body = @{ value = @($d) } } }
            return @{ Status = 200; Body = $d }
        }
        Rejects { Get-CleanupDeployment } 'owned receipt'
    }
    Check 'cleanup graph rejects nested and top-level foreign resources' {
        $d = Deployment
        $d.properties.outputResources += @{ id = "$(Get-GroupPath)/providers/Microsoft.KeyVault/vaults/unrelated" }
        Rejects { Assert-DeploymentGraph $d } 'foreign resource'
        $d = Deployment
        $d.properties.outputResources = @(@{ id = "$(Get-GroupPath)/providers/Microsoft.Resources/deployments/filevault-storage" })
        $script:Http = {
            $nested = Deployment
            $nested.properties.outputResources = @(@{ id = '/subscriptions/other/resourceGroups/foreign' })
            return @{ Status = 200; Body = $nested }
        }
        Rejects { Assert-DeploymentGraph $d } 'foreign resource'
    }
    Check 'cleanup rejects ambiguous fallback and missing inventories' {
        $script:Http = {
            $d = Deployment; $d.tags = @{}; $d.name = 'other-offline-hint'
            return @{ Status = 200; Body = @{ value = @($d) } }
        }
        Rejects { Get-CleanupDeployment } 'unambiguous'
        $d = Deployment; $d.properties.Remove('outputResources')
        Rejects { Assert-DeploymentGraph $d } 'complete'
    }
    Check 'predown refuses a foreign RG resource before asking for deletion' {
        $before = [Environment]::GetEnvironmentVariable('AZURE_RESOURCE_GROUP')
        try {
            [Environment]::SetEnvironmentVariable('AZURE_RESOURCE_GROUP', $script:State.ResourceGroup)
            $script:State.ProvisioningDeploymentId = (Deployment).id
            $script:State.ProvisioningTemplateHash = '1234'; Save-State
            $script:Http = { param($method, $path)
                Expect ($method -eq 'GET') 'predown must not delete or mutate resources.'
                if ($path -eq (Get-GroupPath)) { return @{ Status = 200; Body = Owned (Get-GroupPath) } }
                if ($path -eq (Get-AppPath)) { return @{ Status = 200; Body = App } }
                if ($path -eq (Get-StoragePath)) { return @{ Status = 200; Body = Storage } }
                if ($path -like '*/resources') { return @{ Status = 200; Body = @{ value = @(@{ id = "$(Get-GroupPath)/providers/Microsoft.KeyVault/vaults/foreign" }) } } }
                if ($path -like '*/deployments') { return @{ Status = 200; Body = @{ value = @(Deployment) } } }
                return @{ Status = 200; Body = Deployment }
            }
            Rejects { Invoke-Predown } 'Foreign resource'
        } finally { [Environment]::SetEnvironmentVariable('AZURE_RESOURCE_GROUP', $before) }
    }
    Write-Host "$passed offline PowerShell checks passed."
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force
}

#Requires -Modules Az.Accounts, Az.Resources
<#
.SYNOPSIS
    Validates that workload identity resources created by New-WorkloadIdentity.ps1 are correctly configured.

.DESCRIPTION
    Reads the same params file used by New-WorkloadIdentity.ps1 and for each entry verifies:
      - App registration and service principal exist
      - No client secret is present (workload identity only)
      - Correct role is assigned on the target subscription
      - Expected API permissions are present
      - Federated credential exists (if CreateServiceConnection=true)
      - ADO service connection exists (if CreateServiceConnection=true)

    Exits with code 1 if any check fails — suitable for use in CI pipelines.

.PARAMETER ParamsFile
    Path to the JSON parameters file. Defaults to 'config/example.json'.

.EXAMPLE
    .\Test-WorkloadIdentity.ps1 -ParamsFile 'config\my-params.json'
#>
[CmdletBinding()]
param (
    [Parameter()]
    [ValidateScript({ Test-Path $_ })]
    [string] $ParamsFile = 'config\example.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-AzContext)) {
    throw 'No Azure context found. Run Connect-AzAccount before invoking this script.'
}

$moduleRoot = Join-Path $PSScriptRoot 'modules'
. (Join-Path $moduleRoot 'Authentication.ps1')

Write-Verbose "Reading parameters from '$ParamsFile'..."
$params = Get-Content $ParamsFile -Raw | ConvertFrom-Json

$allResults = @()

foreach ($param in $params) {
    $subscriptionName = $param.SubscriptionName
    $createServiceConnection = [System.Convert]::ToBoolean($param.CreateServiceConnection)
    $role            = $param.PSObject.Properties['Role']                 ? $param.Role                 : 'Contributor'
    $apiPermissions  = $param.PSObject.Properties['ApiPermissions']        ? $param.ApiPermissions       : @()
    $spName          = $param.PSObject.Properties['ServicePrincipalName']  ? $param.ServicePrincipalName : "app-$subscriptionName-devops"
    $orgName         = $param.PSObject.Properties['OrgName']               ? $param.OrgName              : $null
    $projectName     = $param.PSObject.Properties['ProjectName']           ? $param.ProjectName          : $null

    Write-Host "`n=== $subscriptionName ===" -ForegroundColor Cyan

    $results = @()

    $check = { param($name, $pass, $detail)
        [PSCustomObject]@{ Check = $name; Status = if ($pass) { 'PASS' } else { 'FAIL' }; Detail = $detail }
    }

    # Subscription resolves
    $subscriptionId = (Get-AzSubscription -SubscriptionName $subscriptionName -ErrorAction SilentlyContinue).Id
    $results += & $check "Subscription '$subscriptionName' found" ($null -ne $subscriptionId) ($subscriptionId ?? 'NOT FOUND')
    if (-not $subscriptionId) { $allResults += $results; continue }

    Set-AzContext -SubscriptionId $subscriptionId | Out-Null

    # App registration exists
    $app = Get-AzADApplication -DisplayName $spName -ErrorAction SilentlyContinue
    $results += & $check "App registration '$spName' exists" ($null -ne $app) ($app ? $app.AppId : 'NOT FOUND')

    # Service principal exists
    $sp = Get-AzADServicePrincipal -DisplayName $spName -ErrorAction SilentlyContinue
    $results += & $check "Service principal '$spName' exists" ($null -ne $sp) ($sp ? $sp.Id : 'NOT FOUND')

    if ($app) {
        # No client secret
        $creds = Get-AzADAppCredential -ApplicationId $app.AppId -ErrorAction SilentlyContinue
        $hasSecret = $creds | Where-Object { $_.Type -eq 'Password' }
        $results += & $check 'No client secret (workload identity only)' (-not $hasSecret) ($hasSecret ? 'SECRET PRESENT — should be removed' : 'Clean')

        # API permissions
        if ($apiPermissions.Count -gt 0) {
            $existing = Get-AzADAppPermission -ApplicationId $app.AppId -ErrorAction SilentlyContinue
            foreach ($perm in $apiPermissions) {
                $found = $existing | Where-Object { $_.Id -eq $perm.PermissionId -and $_.Type -eq $perm.Type }
                $results += & $check "API permission: $($perm.Name)" ($null -ne $found) ($found ? 'Present' : 'MISSING')
            }
        } else {
            $results += & $check 'API permissions (none expected)' $true 'No permissions required'
        }

        # Federated credential
        if ($createServiceConnection) {
            $connectionName = "conn-$spName"
            $fedCreds = az ad app federated-credential list --id $app.AppId 2>/dev/null | ConvertFrom-Json
            $fedCred  = $fedCreds | Where-Object { $_.name -eq 'AzureDevOps' -and $_.subject -like "*$connectionName*" }
            $results += & $check "Federated credential 'AzureDevOps' on app registration" ($null -ne $fedCred) ($fedCred ? "Subject: $($fedCred.subject)" : 'MISSING')
        }
    }

    # Role assignment
    if ($sp) {
        $roleAssignment = Get-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName $role `
            -Scope "/subscriptions/$subscriptionId" -ErrorAction SilentlyContinue
        $results += & $check "'$role' role on subscription" ($null -ne $roleAssignment) ($roleAssignment ? "Scope: /subscriptions/$subscriptionId" : 'NOT ASSIGNED')
    }

    # ADO service connection
    if ($createServiceConnection -and $orgName -and $projectName) {
        try {
            $token = Get-AzDevOpsAccessToken
            $headers = @{ Authorization = "Bearer $token" }
            $connectionName = "conn-$spName"
            $uri = "https://dev.azure.com/$orgName/$([Uri]::EscapeDataString($projectName))/_apis/serviceendpoint/endpoints?endpointNames=$connectionName&api-version=7.2-preview.4"
            $sc = (Invoke-RestMethod -Method Get -Uri $uri -Headers $headers).value | Where-Object { $_.name -eq $connectionName }
            $results += & $check "ADO service connection '$connectionName' exists" ($null -ne $sc) ($sc ? "ID: $($sc.id)" : 'NOT FOUND')
            if ($sc) {
                $results += & $check "Service connection scheme is WorkloadIdentityFederation" ($sc.authorization.scheme -eq 'WorkloadIdentityFederation') $sc.authorization.scheme
            }
        } catch {
            $results += & $check "ADO service connection check" $false "Error: $_"
        }
    }

    $results | Format-Table -AutoSize
    $allResults += $results
}

$pass = ($allResults | Where-Object Status -eq 'PASS').Count
$fail = ($allResults | Where-Object Status -eq 'FAIL').Count
Write-Host "`nOverall — Pass: $pass  Fail: $fail  Total: $($allResults.Count)" -ForegroundColor ($fail -gt 0 ? 'Red' : 'Green')

if ($fail -gt 0) { exit 1 }

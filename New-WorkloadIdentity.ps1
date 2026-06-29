#Requires -Modules Az.Accounts, Az.Resources
<#
.SYNOPSIS
    Creates Entra ID app registrations with workload identity federation for Azure DevOps service connections.

.DESCRIPTION
    Reads a JSON parameters file and for each subscription entry:
      1. Creates (or reuses) an Entra ID app registration and service principal
      2. Removes any client secret (workload identity uses federation, not secrets)
      3. Assigns the Owner role on the subscription
      4. Adds the Directory.Read.All API permission and grants admin consent
      5. Optionally creates an Azure DevOps service connection and wires the federated credential

    Idempotent — skips steps where the resource already exists.

.PARAMETER ParamsFile
    Path to the JSON parameters file. Defaults to 'config/example.json'.
    See config/example.json for the required schema.

.EXAMPLE
    .\New-WorkloadIdentity.ps1 -ParamsFile 'config/my-params.json'

.EXAMPLE
    .\New-WorkloadIdentity.ps1 -Verbose
#>
[CmdletBinding()]
param (
    [Parameter()]
    [ValidateScript({ Test-Path $_ })]
    [string] $ParamsFile = 'config\example.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Verify Az context
if (-not (Get-AzContext)) {
    throw 'No Azure context found. Run Connect-AzAccount before invoking this script.'
}

# Dot-source modules relative to the script location
$moduleRoot = Join-Path $PSScriptRoot 'modules'
. (Join-Path $moduleRoot 'Authentication.ps1')
. (Join-Path $moduleRoot 'Service-Connection.ps1')

Write-Verbose "Reading parameters from '$ParamsFile'..."
$params = Get-Content $ParamsFile -Raw | ConvertFrom-Json

foreach ($param in $params) {
    $subscriptionName = $param.SubscriptionName
    $createServiceConnection = [System.Convert]::ToBoolean($param.CreateServiceConnection)
    $orgName = $param.OrgName
    $projectName = $param.ProjectName

    Write-Host "`n=== Processing: $subscriptionName ===" -ForegroundColor Cyan

    $spName = "app-$subscriptionName-devops"

    # Resolve subscription
    $subscriptionId = (Get-AzSubscription -SubscriptionName $subscriptionName -ErrorAction SilentlyContinue).Id
    if (-not $subscriptionId) {
        Write-Warning "Subscription '$subscriptionName' not found — skipping."
        continue
    }

    Set-AzContext -SubscriptionId $subscriptionId | Out-Null
    Write-Verbose "Context set to '$subscriptionName' ($subscriptionId)."

    # Create or reuse service principal
    $existingSp = Get-AzADServicePrincipal -DisplayName $spName -ErrorAction SilentlyContinue
    if ($existingSp) {
        Write-Verbose "Service principal '$spName' already exists — reusing."
        $sp = $existingSp
    } else {
        Write-Verbose "Creating service principal '$spName'..."
        $sp = New-AzADServicePrincipal -DisplayName $spName
        Write-Host "  Created service principal '$spName'." -ForegroundColor Green
    }

    # Remove client secret (workload identity uses federation only)
    try {
        Get-AzADApplication -DisplayName $spName | Remove-AzADAppCredential -ErrorAction SilentlyContinue
        Write-Verbose "Client secret removed (if any existed)."
    } catch {
        Write-Warning "Could not remove client secret from '$spName': $_"
    }

    # Assign Owner role on the subscription
    $existingRole = Get-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName 'Owner' `
        -Scope "/subscriptions/$subscriptionId" -ErrorAction SilentlyContinue
    if ($existingRole) {
        Write-Verbose "Owner role already assigned — skipping."
    } else {
        Write-Verbose "Assigning Owner role..."
        New-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName 'Owner' `
            -Scope "/subscriptions/$subscriptionId" | Out-Null
        Write-Host "  Assigned Owner role on '$subscriptionName'." -ForegroundColor Green
    }

    # Add Directory.Read.All API permission
    $spnApp   = Get-AzADApplication -DisplayName $spName
    $graphApiId    = '00000003-0000-0000-c000-000000000000'
    $directoryRead = '7ab1d382-f21e-4acd-a863-ba3e13f7da61'

    $existing = Get-AzADAppPermission -ApplicationId $spnApp.AppId |
        Where-Object { $_.ApiId -eq $graphApiId -and $_.Id -eq $directoryRead }

    if ($existing) {
        Write-Verbose "Directory.Read.All permission already exists — skipping."
    } else {
        Write-Verbose "Adding Directory.Read.All permission..."
        Add-AzADAppPermission -ApplicationId $spnApp.AppId -ApiId $graphApiId `
            -PermissionId $directoryRead -Type 'Role'
        Write-Host "  Added Directory.Read.All permission." -ForegroundColor Green
    }

    # Grant admin consent via Azure CLI
    # Brief pause to allow the permission to propagate before consent
    Start-Sleep -Seconds 10
    Write-Verbose "Granting admin consent..."
    $null = az ad app permission admin-consent --id $spnApp.AppId 2>&1
    Write-Host "  Admin consent granted." -ForegroundColor Green

    # Summary output
    Write-Host "  App ID        : $($sp.AppId)"
    Write-Host "  Tenant ID     : $($sp.AppOwnerOrganizationId)"
    Write-Host "  Subscription  : $subscriptionName ($subscriptionId)"

    # Optionally create the ADO service connection
    if (-not $createServiceConnection) {
        Write-Verbose "CreateServiceConnection=false — skipping ADO service connection."
        continue
    }

    Write-Verbose "Creating Azure DevOps service connection..."
    $token = Get-AzDevOpsAccessToken

    $connectionName = "conn-$spName"
    $sc = New-AzDevOpsAzureSubscriptionServiceConnection `
        -OrgName                  $orgName `
        -ProjectName              $projectName `
        -Name                     $connectionName `
        -SubscriptionId           $subscriptionId `
        -SubscriptionName         $subscriptionName `
        -ServicePrincipalClientId $sp.AppId `
        -ServicePrincipalTenantId $sp.AppOwnerOrganizationId `
        -AccessToken              $token

    $issuer = (Get-AzDevOpsAzureServiceConnection `
        -OrgName            $orgName `
        -ProjectName        $projectName `
        -Name               $connectionName `
        -ServiceConnectionId $sc.id `
        -AccessToken        $token).authorization.parameters.workloadIdentityFederationIssuer

    $appObjectId = (Get-AzADApplication -DisplayName $spName).Id
    $subject     = "sc://$orgName/$projectName/$connectionName"

    New-AzADAppFederatedCredential `
        -ApplicationObjectId $appObjectId `
        -Issuer              $issuer `
        -Subject             $subject `
        -Audience            'api://AzureADTokenExchange' `
        -Name                'AzureDevOps' | Out-Null

    Write-Host "  Service connection '$connectionName' created and federated credential wired." -ForegroundColor Green
}

Write-Host "`nDone." -ForegroundColor Cyan

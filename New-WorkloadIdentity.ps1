#Requires -Modules Az.Accounts, Az.Resources
<#
.SYNOPSIS
    Creates Entra ID app registrations with workload identity federation for Azure DevOps service connections.

.DESCRIPTION
    Reads a JSON parameters file and for each subscription entry:
      1. Creates (or reuses) an Entra ID app registration and service principal
      2. Removes any client secret (workload identity uses federation, not secrets)
      3. Assigns the specified role on the subscription (default: Contributor)
      4. Optionally adds Microsoft Graph API permissions and grants admin consent
      5. Optionally creates an Azure DevOps service connection and wires the federated credential

    Idempotent — skips steps where the resource already exists.

    Follows the principle of least privilege: Contributor is the default role and no API
    permissions are added unless explicitly listed in the params file.

.PARAMETER ParamsFile
    Path to the JSON parameters file. Defaults to 'config/example.json'.
    See config/example.json for the full schema.

.EXAMPLE
    .\New-WorkloadIdentity.ps1 -ParamsFile 'config\my-params.json'

.EXAMPLE
    .\New-WorkloadIdentity.ps1 -ParamsFile 'config\my-params.json' -Verbose
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
. (Join-Path $moduleRoot 'Service-Connection.ps1')

Write-Verbose "Reading parameters from '$ParamsFile'..."
$params = Get-Content $ParamsFile -Raw | ConvertFrom-Json

foreach ($param in $params) {
    $subscriptionName = $param.SubscriptionName
    $createServiceConnection = [System.Convert]::ToBoolean($param.CreateServiceConnection)
    $orgName    = $param.PSObject.Properties['OrgName']     ? $param.OrgName     : $null
    $projectName = $param.PSObject.Properties['ProjectName'] ? $param.ProjectName : $null

    # PoLP defaults — explicitly override in params when broader access is required
    $role   = $param.PSObject.Properties['Role']                  ? $param.Role                  : 'Contributor'
    $apiPermissions = $param.PSObject.Properties['ApiPermissions'] ? $param.ApiPermissions        : @()
    $spName = $param.PSObject.Properties['ServicePrincipalName']  ? $param.ServicePrincipalName  : "app-$subscriptionName-devops"

    Write-Host "`n=== Processing: $subscriptionName (role: $role) ===" -ForegroundColor Cyan

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

    # Remove client secret — workload identity uses federation only
    try {
        Get-AzADApplication -DisplayName $spName | Remove-AzADAppCredential -ErrorAction SilentlyContinue
        Write-Verbose "Client secret removed (if any existed)."
    } catch {
        Write-Warning "Could not remove client secret from '$spName': $_"
    }

    # Assign role on the subscription
    $existingRole = Get-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName $role `
        -Scope "/subscriptions/$subscriptionId" -ErrorAction SilentlyContinue
    if ($existingRole) {
        Write-Verbose "'$role' role already assigned — skipping."
    } else {
        Write-Verbose "Assigning '$role' role..."
        New-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName $role `
            -Scope "/subscriptions/$subscriptionId" | Out-Null
        Write-Host "  Assigned '$role' role on '$subscriptionName'." -ForegroundColor Green
    }

    # Add API permissions (only what is explicitly listed — none by default)
    $spnApp = Get-AzADApplication -DisplayName $spName

    if ($apiPermissions.Count -gt 0) {
        $existingPermissions = Get-AzADAppPermission -ApplicationId $spnApp.AppId

        foreach ($perm in $apiPermissions) {
            $alreadyExists = $existingPermissions | Where-Object {
                $_.ApiId -eq $perm.ApiId -and $_.Id -eq $perm.PermissionId -and $_.Type -eq $perm.Type
            }
            if ($alreadyExists) {
                Write-Verbose "Permission '$($perm.Name)' already exists — skipping."
            } else {
                Write-Verbose "Adding permission '$($perm.Name)'..."
                Add-AzADAppPermission -ApplicationId $spnApp.AppId `
                    -ApiId $perm.ApiId -PermissionId $perm.PermissionId -Type $perm.Type
                Write-Host "  Added permission '$($perm.Name)'." -ForegroundColor Green
            }
        }

        # Grant admin consent only when permissions were specified
        Start-Sleep -Seconds 10
        Write-Verbose "Granting admin consent..."
        $null = az ad app permission admin-consent --id $spnApp.AppId 2>&1
        Write-Host "  Admin consent granted." -ForegroundColor Green
    } else {
        Write-Verbose "No ApiPermissions specified — skipping Graph permissions and admin consent."
    }

    Write-Host "  App ID        : $($sp.AppId)"
    Write-Host "  Tenant ID     : $($sp.AppOwnerOrganizationId)"
    Write-Host "  Subscription  : $subscriptionName ($subscriptionId)"
    Write-Host "  Role          : $role"

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
        -OrgName             $orgName `
        -ProjectName         $projectName `
        -Name                $connectionName `
        -ServiceConnectionId $sc.id `
        -AccessToken         $token).authorization.parameters.workloadIdentityFederationIssuer

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

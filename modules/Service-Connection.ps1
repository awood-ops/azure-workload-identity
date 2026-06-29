<#
.SYNOPSIS
    Creates and retrieves Azure DevOps service connections via the REST API.
#>

function New-AzDevOpsAzureSubscriptionServiceConnection {
    <#
    .SYNOPSIS
        Creates an Azure Resource Manager service connection scoped to a subscription.
    #>
    param (
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $OrgName,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ProjectName,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Name,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $SubscriptionId,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $SubscriptionName,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ServicePrincipalClientId,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ServicePrincipalTenantId,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $AccessToken
    )

    Write-Host "Creating service connection '$Name' in project '$ProjectName'..." -ForegroundColor Cyan

    $headers = @{
        Authorization  = "Bearer $AccessToken"
        'Content-Type' = 'application/json'
    }

    $project = Invoke-RestMethod -Method Get -Headers $headers `
        -Uri "https://dev.azure.com/$OrgName/_apis/projects/$([Uri]::EscapeDataString($ProjectName))?api-version=7.2-preview.4"

    $body = @{
        data = @{
            subscriptionId   = $SubscriptionId
            subscriptionName = $SubscriptionName
            environment      = 'AzureCloud'
            scopeLevel       = 'Subscription'
            creationMode     = 'Manual'
        }
        name          = $Name
        type          = 'AzureRM'
        url           = 'https://management.azure.com/'
        authorization = @{
            parameters = @{
                tenantid             = $ServicePrincipalTenantId
                serviceprincipalid   = $ServicePrincipalClientId
            }
            scheme = 'WorkloadIdentityFederation'
        }
        isShared  = $false
        isReady   = $true
        serviceEndpointProjectReferences = @(@{
            projectReference = @{ name = $ProjectName; id = $project.id }
            name             = $Name
        })
    } | ConvertTo-Json -Depth 10

    $result = Invoke-RestMethod -Method Post -Headers $headers -Body $body `
        -Uri "https://dev.azure.com/$OrgName/_apis/serviceendpoint/endpoints?api-version=7.2-preview.4"

    Write-Host "  Service connection '$Name' created." -ForegroundColor Green
    return $result
}

function New-AzDevOpsAzureManagementGroupServiceConnection {
    <#
    .SYNOPSIS
        Creates an Azure Resource Manager service connection scoped to a management group.
    #>
    param (
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $OrgName,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ProjectName,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Name,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ManagementGroupId,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ManagementGroupName,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ServicePrincipalClientId,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ServicePrincipalTenantId,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $AccessToken
    )

    Write-Host "Creating management group service connection '$Name' in project '$ProjectName'..." -ForegroundColor Cyan

    $headers = @{
        Authorization  = "Bearer $AccessToken"
        'Content-Type' = 'application/json'
    }

    $project = Invoke-RestMethod -Method Get -Headers $headers `
        -Uri "https://dev.azure.com/$OrgName/_apis/projects/$([Uri]::EscapeDataString($ProjectName))?api-version=7.2-preview.4"

    $body = @{
        data = @{
            managementGroupId   = $ManagementGroupId
            managementGroupName = $ManagementGroupName
            environment         = 'AzureCloud'
            scopeLevel          = 'ManagementGroup'
            creationMode        = 'Manual'
        }
        name          = $Name
        type          = 'AzureRM'
        url           = 'https://management.azure.com/'
        authorization = @{
            parameters = @{
                tenantid           = $ServicePrincipalTenantId
                serviceprincipalid = $ServicePrincipalClientId
            }
            scheme = 'WorkloadIdentityFederation'
        }
        isShared  = $false
        isReady   = $true
        serviceEndpointProjectReferences = @(@{
            projectReference = @{ name = $ProjectName; id = $project.id }
            name             = $Name
        })
    } | ConvertTo-Json -Depth 10

    $result = Invoke-RestMethod -Method Post -Headers $headers -Body $body `
        -Uri "https://dev.azure.com/$OrgName/_apis/serviceendpoint/endpoints?api-version=7.2-preview.4"

    Write-Host "  Service connection '$Name' created." -ForegroundColor Green
    return $result
}

function Get-AzDevOpsAzureServiceConnection {
    <#
    .SYNOPSIS
        Retrieves an Azure DevOps service connection by ID.
    #>
    param (
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $OrgName,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ProjectName,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ServiceConnectionId,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Name,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $AccessToken
    )

    $headers = @{
        Authorization  = "Bearer $AccessToken"
        'Content-Type' = 'application/json'
    }

    return Invoke-RestMethod -Method Get -Headers $headers `
        -Uri "https://dev.azure.com/$OrgName/$([Uri]::EscapeDataString($ProjectName))/_apis/serviceendpoint/endpoints/$ServiceConnectionId`?api-version=7.2-preview.4"
}

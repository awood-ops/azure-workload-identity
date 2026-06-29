<#
.SYNOPSIS
    Returns an access token for calling the Azure DevOps REST APIs.

.DESCRIPTION
    Uses the current Az context to obtain a bearer token scoped to Azure DevOps.
    Run Connect-AzAccount before calling this function.

    The resource ID '499b84ac-1321-427f-aa17-267ca6975798' is the fixed Azure DevOps
    resource identifier — do not change it.
#>
function Get-AzDevOpsAccessToken {
    return (Get-AzAccessToken -ResourceUrl '499b84ac-1321-427f-aa17-267ca6975798').Token
}

<#
.SYNOPSIS
    Verifies the current Az context matches expected parameters and re-authenticates if needed.

.DESCRIPTION
    Compares the active Az context against the supplied account, subscription, and tenant.
    If they differ, the user is prompted to continue with the current context or re-authenticate
    via device code (to avoid MFA issues).

    Intended for interactive scripts where the caller needs to confirm the right context before
    making changes. Automation scripts should manage context directly with Set-AzContext.

.PARAMETER AzureUserName
    Expected UPN of the signed-in user.

.PARAMETER SubscriptionId
    Expected subscription ID.

.PARAMETER TenantId
    Expected tenant ID.
#>
function Set-AzureAuthentication {
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $AzureUserName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $TenantId
    )

    $context = Get-AzContext

    if ($null -ne $context) {
        Write-Host 'Current Azure context:' -ForegroundColor Cyan
        Write-Host "  Account     : $($context.Account)"          -ForegroundColor Cyan
        Write-Host "  Subscription: $($context.Subscription.Name) ($($context.Subscription.Id))" -ForegroundColor Cyan
        Write-Host "  Tenant      : $($context.Tenant.Id)"        -ForegroundColor Cyan

        $match = $context.Account.Id -eq $AzureUserName -and
                 $context.Subscription.Id -eq $SubscriptionId -and
                 $context.Tenant.Id -eq $TenantId

        if (-not $match) {
            Write-Warning 'Current context does not match the expected values.'
            $reply = Read-Host 'Continue with current context? (y = yes, n = re-authenticate)'
            if ($reply -notmatch '^[Yy]$') {
                Connect-AzAccount -Tenant $TenantId -Subscription $SubscriptionId -UseDeviceAuthentication
            }
        } else {
            Write-Host 'Context matches — continuing.' -ForegroundColor Green
        }
    } else {
        Connect-AzAccount -Tenant $TenantId -Subscription $SubscriptionId -UseDeviceAuthentication
    }

    return Get-AzContext
}

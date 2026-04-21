[CmdletBinding()]
param (
    [switch]
    $disconnect
)

if ($disconnect) {
    Write-Host "🔌 Disconnecting from Azure..." -ForegroundColor Yellow
    Disconnect-AzAccount -Confirm:$false
    Write-Host "✅ Successfully disconnected from Azure!" -ForegroundColor Green
    exit 0
}

# Verify if there's an active Azure session
$context = Get-AzContext -ErrorAction SilentlyContinue

if ($null -eq $context) {
    Write-Host "🔐 No active session found. Initiating secure WAM login..." -ForegroundColor Yellow

    Connect-AzAccount
    $context = Get-AzContext

    Write-Host "✅ Successfully connected to Azure!" -ForegroundColor Green
}
else {
    Write-Host "✅ Active session detected. Using existing context..." -ForegroundColor Green
    Write-Host "---------------------------------------------------" -ForegroundColor Cyan
    Write-Host "Connected to : $($context.Subscription.Name)"        -ForegroundColor Green
    Write-Host "Account      : $($context.Account.Id)"
    Write-Host "Tenant       : $($context.Tenant.Id)"
    Write-Host "---------------------------------------------------" -ForegroundColor Cyan
}

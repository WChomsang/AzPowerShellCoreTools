[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [string]
    $Name
)

$resourceGroup = Get-AzResourceGroup -Name $Name -ErrorAction SilentlyContinue
if ($null -ne $resourceGroup) {
    Write-Host "⚠️ Resource Group '$Name' exists. Deleting..." -ForegroundColor Yellow
    Remove-AzResourceGroup -Name $Name -Force -AsJob | Out-Null
    Write-Host "✅ Deletion of Resource Group '$Name' initiated. Please check Azure Portal for status." -ForegroundColor Green
}
else {
    Write-Host "❌ Resource Group '$Name' does not exist." -ForegroundColor Red
}
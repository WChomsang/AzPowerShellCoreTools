[CmdletBinding()]
param (
    [string]
    $Name = "Sandbox-Playground",

    [ValidateSet("East US", "West US", "West Europe", "Southeast Asia")]
    [string]
    $Location = "Southeast Asia"
)

$resourceGroup = Get-AzResourceGroup -Name $Name -ErrorAction SilentlyContinue
if ($null -ne $resourceGroup) {
    Write-Host "⚠️ Resource Group '$Name' already exists. Please choose a different name." -ForegroundColor Red
    exit 1
}
else {
    Write-Host "🚀 Creating Resource Group '$Name'..." -ForegroundColor Yellow
    New-AzResourceGroup -Name $Name -Location $Location | Out-Null
    Write-Host "✅ Resource Group '$Name' created successfully!" -ForegroundColor Green

    # verify creation
    $createdResourceGroup = Get-AzResourceGroup -Name $Name -ErrorAction SilentlyContinue
    if ($null -ne $createdResourceGroup) {
        Write-Host "🔍 Verifying Resource Group '$Name'..." -ForegroundColor Yellow
        Write-Host "✅ Resource Group '$Name' exists and is ready for use!" -ForegroundColor Green
    }
    else {
        Write-Host "❌ Failed to verify the creation of Resource Group '$Name'. Please check Azure Portal." -ForegroundColor Red
        exit 1
    }
}
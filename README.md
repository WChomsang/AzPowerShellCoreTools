# AzPowerShellCoreTools

PowerShell scripts for handling small Azure tasks using the Az module.

## Prerequisites

- [Azure PowerShell (Az module)](https://learn.microsoft.com/en-us/powershell/azure/install-az-ps)

## Scripts

### `helper/connect.ps1`

Manages Azure session authentication.

```powershell
# Connect to Azure
.\helper\connect.ps1

# Disconnect from Azure
.\helper\connect.ps1 -disconnect
```

### `New-RG.ps1`

Creates a new Azure Resource Group.

| Parameter  | Required | Default              | Description                                          |
|------------|----------|----------------------|------------------------------------------------------|
| `Name`     | No       | `Sandbox-Playground` | Name of the Resource Group                           |
| `Location` | No       | `Southeast Asia`     | Azure region (`East US`, `West US`, `West Europe`, `Southeast Asia`) |

```powershell
# Create with defaults
.\New-RG.ps1

# Create with custom name and location
.\New-RG.ps1 -Name "MyResourceGroup" -Location "East US"
```

### `Delete-RG.ps1`

Deletes an existing Azure Resource Group (runs as background job).

| Parameter | Required | Description                    |
|-----------|----------|--------------------------------|
| `Name`    | Yes      | Name of the Resource Group to delete |

```powershell
.\Delete-RG.ps1 -Name "MyResourceGroup"
```

# #############################################################################
# Josh Carpenter - SCRIPT - POWERSHELL
# NAME: DynamicEntitlementRefresh.ps1
# 
# AUTHOR: Josh Carpenter
# DATE: 2018/12/27
# EMAIL: joshua.paul.carpenter@gmail.com

# VERSION HISTORY
# 1.0 2018.12.27 Initial Version. 
#
# #############################################################################
<#

.SYNOPSIS
Queries AD entitlement groups to determine which have been modified in the last 15 minutes. For those that have been modified, the corresponding SCCM collection will be refreshed.

.DESCRIPTION
This is used in an environment where all entitlement security groups exist in a single OU in active directory. 
Additionally the entitlement group name corresponds exactly with the collection name in SCCM, except for NR licensed software, 
which creates two different collections (one for users, one for devices).

License types:
-Users (licensed to user object only)
-Devices (Licended to a computer object only)
-NR (Non-Restricted - can be licensed to a user or a computer object)

.EXAMPLE
./DynamicEntitlementRefresh.ps1 -CMServer [SCCM Server Hostname] -SearchBase "OU=Entitlements,OU=Groups,DC=Contoso,DC=org"

.NOTES
You may need to adapt this to your own AD and SCCM structure, so that you can accurately identify entitlement AD groups and corresponding SCCM collections.

.LINK
https://github.com/RobotScience/SCCM

#>
Param(
    [Parameter(Mandatory=$true)]
    [string]$CMServer,
    [Parameter(Mandatory=$true)]
    [string]$SearchBase
)
#Create log file
$getDt = Get-Date -Format yyyyMMdd-HHmmss
$logPath = "C:\scripts\powershell\DynamicEntitlementRefresh\logs\$getDt.log"
if (!(Test-Path -Path $logPath)) { New-Item -ItemType File $logPath -Force }
#Remove log files older than 90 days
Get-ChildItem -Path "C:\scripts\powershell\DynamicEntitlementRefresh\logs" -Include *.log -Recurse | Where-Object -Property LastWriteTime -lt (Get-Date).AddDays(-30) | Remove-Item -Force
#Begin logging
Start-Transcript -Path $logPath -Append -NoClobber -IncludeInvocationHeader
#Import ConfigMgr & AD module and get site code
Try { 
    Import-Module -Name ActiveDirectory -ErrorAction Stop
    Import-Module (Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH) ConfigurationManager.psd1) -ErrorAction Stop
}
Catch {
    Write-Output "Unable to import modules! Please fix and re-run this script."
    Stop-Transcript
    Exit
}
$getSiteCode = Get-WmiObject -ComputerName $CMServer -Namespace "root\SMS" -Class "SMS_ProviderLocation" | Select-Object -ExpandProperty SiteCode
$siteCode = $getSiteCode + ":"
#Get all entitlement AD groups that were modified in the last 15 minutes
$back15 = (Get-Date).AddMinutes(-15)
$modEntGrps = Get-ADGroup -SearchBase $SearchBase -Properties modified -Filter { modified -gt $back15 } | Select-Object -Property samaccountname,modified
#If AD groups were found, search for the corresponding entitlement collections in SCCM
if ($modEntGrps) {
    Write-Host ($modEntGrps.Count) "AD groups have been modified in the last 15 minutes:"
    Write-Output $modEntGrps
    Write-Output ""
    [System.Collections.ArrayList]$grpList = @()
    foreach ($grp in ($modEntGrps.SamAccountName)) {
        if ($grp -like "*_NR") {
            $grpD = $grp + "-D"
            $grpU = $grp + "-U"
            $grpList += $grpD,$grpU
        }
        Else { $grpList += $grp }
    }
    Push-Location -Path $siteCode
    foreach ($coll in $grpList) {
        $collId = Get-CMCollection -Name $coll | Select-Object -ExpandProperty CollectionID
        if ($collId) {
            Write-Output "Invoking refresh for collection $coll, with collection ID: $collId..."
            Write-Output ""
            Invoke-WmiMethod -Path "ROOT\SMS\Site_SHS:SMS_Collection.CollectionId='$collId'" -Name RequestRefresh -ComputerName $CMServer
        }
    }
    Pop-Location
}
Else { Write-Output "No AD Entitlement groups were modified in the last 15 minutes. Nothing to do..." }
Stop-Transcript
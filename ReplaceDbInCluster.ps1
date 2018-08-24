cls

Import-Module “sqlps” -DisableNameChecking
Import-Module FailoverClusters
Set-Location c:\

$PermDashboardDbName = 'EdFi_Dashboard'
$TempDashboardDbName = "$($PermDashboardDbName)_temp"
$DroppableDashboardDbName = "$($PermDashboardDbName)_Old"
$LogFilePath = 'D:\NightlyJobLogs\AutomatedBackup.log'
$AvGroupName = 'EdFiProdAvGroup'

$Secvals = Get-SECSecretValue -SecretId edfi-prod-pw-list
$Secrets = ConvertFrom-Json $Secvals.SecretString


$OdsAdminPw = $Secrets.'ods-admin-prod-pw'
$BackupSharePw = $Secrets.'webserver-user-prod-pw'

function LogMsg($MsgToLog)
{
    Write-Host "$(Get-Date -format 'u') $MsgToLog `r`n"
  try 
  {
    Add-Content $LogFilePath "$(Get-Date -format 'u') $MsgToLog `r`n"
  }
  catch {}
}

LogMsg("Preparing Credentials")
$SecPasswd1 = ConvertTo-SecureString "$BackupSharePw" -AsPlainText -Force
$BackupAccessCreds = New-Object System.Management.Automation.PSCredential ("webserver", $SecPasswd1)
$secpasswd2 = ConvertTo-SecureString "$OdsAdminPw" -AsPlainText -Force
$WSCreds = New-Object System.Management.Automation.PSCredential ("odsadmin", $secpasswd2)

$AGOwnerNodeName = (Get-ClusterResource -Name "EdFiProdAvGroup").OwnerNode.Name 

LogMsg("Check #1 - Is the Cluster up and running?")
$UpNodes = Get-ClusterNode | Where-Object {$_.State -eq "Up"}
if ($UpNodes.Count -lt 3)
{
  LogMsg("No! ABORTING DASHBOARD DATABASE REPLACEMENT!")
  exit -101
}
LogMsg("Yes. Proceeding.")

$PrimaryNodeAddress = '10.222.105.4'
$SecondaryNodeAddress = '10.222.106.70'

if ($AGOwnerNodeName = 'EC2AMAZ-5QGRUAT')
{
    $PrimaryNodeAddress = '10.222.105.4'
    $SecondaryNodeAddress = '10.222.106.70'
}
else 
{
    $PrimaryNodeAddress = '10.222.106.70'
    $SecondaryNodeAddress = '10.222.105.4'
}

$PrimarySqlNodePath = "SQLSERVER:\SQL\$PrimaryNodeAddress\DEFAULT"
$SecondarySqlNodePath = "SQLSERVER:\SQL\$SecondaryNodeAddress\DEFAULT"

$PrimarySQLAvailGroupPath = "$PrimarySqlNodePath\AvailabilityGroups\$AvGroupName"
$SecondarySQLAvailGroupPath = "$SecondarySqlNodePath\AvailabilityGroups\$AvGroupName"

LogMsg("Automated database maintenance script launched. Logging to $LogFilePath")
LogMsg("Primary database server is: $PrimaryNodeAddress.")
LogMsg("Secondary database server is: $SecondaryNodeAddress.")

LogMsg("Deleting the 'K' drive (Primary node's MSSQL Share)")
net use k: /delete /y
LogMsg("Creating the 'K' drive (Primary node's MSSQL Share)")
net use k: "\\$PrimaryNodeAddress\MSSQL" /user:webserver $BackupSharePw /persistent:yes 
LogMsg("Deleting the 'M' drive (Secondary node's MSSQL Share)")
net use m: /delete /y
LogMsg("Creating the 'M' drive (Secondary node's MSSQL Share)")
net use m: "\\$SecondaryNodeAddress\MSSQL" /user:webserver $BackupSharePw /persistent:yes 
LogMsg("Now prepped for file copy between shares")

LogMsg("Check #2 - does the database to replace exist?")
Set-Location $PrimarySqlNodePath
$OldDbOnPrimary = Get-SqlDatabase -Name "$PermDashboardDbName" -ServerInstance "$PrimaryNodeAddress" -Credential $WSCreds 
if ($OldDbOnPrimary -eq $null)
{
  LogMsg("No! ABORTING DASHBOARD DATABASE REPLACEMENT!")
  exit -102
}
if ($OldDbOnPrimary.FileGroups[0] -eq $null)
{
  LogMsg("No! ABORTING DASHBOARD DATABASE REPLACEMENT!")
  exit -103
}
LogMsg("Yes. Proceeding.")

LogMsg("Finding the new database name, one that starts with EdFi_Dashboard_temp ...")
$TempDashboardDbName = (Get-SqlDatabase -ServerInstance "$PrimaryNodeAddress" -Credential $WSCreds | select-object -Property "Name" | where-object Name -Match $TempDashboardDbName  | select-object -First 1).Name


LogMsg("Check #3 - does the new database also exist?")
$NewDbOnPrimary = Get-SqlDatabase -Name "$TempDashboardDbName" -ServerInstance "$PrimaryNodeAddress" -Credential $WSCreds
if ($NewDbOnPrimary -eq $null)
{
  LogMsg("No! ABORTING DASHBOARD DATABASE REPLACEMENT!")
  exit -104
}
if ($NewDbOnPrimary.FileGroups[0] -eq $null)
{
  LogMsg("No! ABORTING DASHBOARD DATABASE REPLACEMENT!")
  exit -105
}
LogMsg("Yes. Proceeding.")

LogMsg("Removing the database $PermDashboardDbName from the availability group (primary).")
Remove-SqlAvailabilityDatabase -Path "$PrimarySQLAvailGroupPath\AvailabilityDatabases\$PermDashboardDbName"
LogMsg("Database should also have been set to 'restoring' mode on the secondary cluster node.")

$PrimarySQLServerInstance = new-object Microsoft.SqlServer.Management.Smo.Server $PrimaryNodeAddress
$SecondarySQLServerInstance = new-object Microsoft.SqlServer.Management.Smo.Server $SecondaryNodeAddress

LogMsg("Dropping the previous dashboard database $PermDashboardDbName from the primary cluster node")
$PrimarySQLServerInstance.KillAllProcesses("$PermDashboardDbName")
$OldDbOnPrimary.Refresh()
$OldDbOnPrimary.Drop()

LogMsg("Renaming $TempDashboardDbName to $PermDashboardDbName")
$PrimarySQLServerInstance.KillAllProcesses("$TempDashboardDbName")
$NewDbOnPrimary.Rename("$PermDashboardDbName")
$NewDbOnPrimary.Alter()
$NewDbOnPrimary.Refresh()
$NewDbOnPrimary.Alter()
$NewDbOnPrimary.Refresh()

LogMsg("Setting new $PermDashboardDbName to FULL recovery mode - required for clustering")
$NewDbOnPrimary.RecoveryModel = "Full"
$PrimarySQLServerInstance.KillAllProcesses("$PermDashboardDbName")
$NewDbOnPrimary.Alter()
$NewDbOnPrimary.Refresh()

LogMsg("Backing up new $PermDashboardDbName in preparation for adding to secondary cluster nodes")
Backup-SqlDatabase -ServerInstance "$PrimaryNodeAddress" -Database "$PermDashboardDbName" -BackupFile "D:\MSSQL\Backup\$PermDashboardDbName.bak" -Credential $WSCreds -Initialize

LogMsg("Dropping the previous dashboard database $PermDashboardDbName from the secondary cluster node")
$OldDbOnSecondary = Get-SqlDatabase -Name "$PermDashboardDbName" -ServerInstance "$SecondaryNodeAddress" -Credential $WSCreds 
$SecondarySQLServerInstance.KillAllProcesses("$PermDashboardDbName")
$OldDbOnSecondary.Refresh()
$OldDbOnSecondary.Drop()

LogMsg("Restoring the new dashboard database as $PermDashboardDbName with REPLACE and NORECOVERY options")
Copy-Item -Path "k:\Backup\$PermDashboardDbName.bak" -Destination "m:\Backup\$PermDashboardDbName.bak" -Force
Restore-SqlDatabase -ServerInstance "$SecondaryNodeAddress" -Database "$PermDashboardDbName" -BackupFile "D:\MSSQL\backup\$PermDashboardDbName.bak" -Credential $WSCreds  -NoRecovery -ReplaceDatabase

LogMsg("Adding the new dashboard database $PermDashboardDbName to the availability group on primary node")
Add-SqlAvailabilityDatabase -Path $PrimarySQLAvailGroupPath -Database "$PermDashboardDbName"

LogMsg("Join the new dashboard database $PermDashboardDbName to the availability group on secondary node")
$D2 = Get-SqlDatabase -Name "master" -ServerInstance "$SecondaryNodeAddress" -Credential $WSCreds 
$D2.ExecuteNonQuery("ALTER DATABASE [$PermDashboardDbName] SET HADR AVAILABILITY GROUP = [EdFiProdAvGroup];")

exit 0
cls

Import-Module “sqlps” -DisableNameChecking
Import-Module FailoverClusters
Set-Location c:\

$LogFilePath = 'D:\MSSQL\SqlAgentJobScripts\AutomatedBackup.log'
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
  LogMsg("No! ABORTING AUTOMATED BACKUP SCRIPT!")
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

LogMsg("Automated database backup script launched. Logging to $LogFilePath")
LogMsg("Primary database server is: $PrimaryNodeAddress.")
LogMsg("Secondary database server is: $SecondaryNodeAddress.")

LogMsg("Deleting the 'M' drive (Secondary node's MSSQL Share)")
net use m: /delete /y
LogMsg("Creating the 'M' drive (Secondary node's MSSQL Share)")
net use m: "\\$SecondaryNodeAddress\MSSQL" /user:webserver $BackupSharePw /persistent:yes 
LogMsg("Now prepped for retrieving database backups")

$PrimarySQLServerInstance = new-object Microsoft.SqlServer.Management.Smo.Server $PrimaryNodeAddress
$SecondarySQLServerInstance = new-object Microsoft.SqlServer.Management.Smo.Server $SecondaryNodeAddress

$DatabasesToBackup = $SecondarySQLServerInstance.Databases | Where-Object { $_.IsSystemObject -eq $false }

$D2 = Get-SqlDatabase -Name "master" -ServerInstance "$SecondaryNodeAddress" -Credential $WSCreds 

$EdFiS3Bucket = "edfi-mpls-database-backups"

Foreach ($Dbase in $DatabasesToBackup)
{
    LogMsg("Backing up database $Dbase")
    $D2.ExecuteNonQuery("BACKUP DATABASE $($Dbase.Name) TO DISK = N'D:\MSSQL\Backup\$($Dbase.Name).bak' WITH  COPY_ONLY, NOFORMAT, INIT, NAME = N'$($Dbase.Name)-Full Database Backup', SKIP, NOREWIND, NOUNLOAD,  STATS = 10")
    Write-S3Object -BucketName $EdFiS3Bucket -Region 'us-east-2' -Key $($Dbase.Name) -File "D:\MSSQL\Backup\$($Dbase.Name).bak" -CannedACLName Private
}

exit 0



<#
.SYNOPSIS
    Convert-TaskSequence will convert a Task Sequence and resolve content dependencies between two SCCM sites.
.DESCRIPTION
    Convert-TaskSequence will query off package display names from Task Sequence content, match the content between two SCCM sites, then adjust Task Sequences accordingly. For example, if your Task Sequence references package CM00001 in a step and CM0001 is a driver package labeled 'Dell Latitude 5590 Windows 10 Drivers', then the script will query the SMS_DriverPackage SMS Provider server class for the matching package in your Production site and adjust the Task Sequence step. This allows you to convert Task Sequences seamlessly between sites without having to adjust the XML by hand to resolve package dependencies.
.PARAMETER devPackageID
    The packageID of the Task Sequence you want to convert from dev.
.PARAMETER devSiteCode
    The site code of the Dev SCCM site.
.PARAMETER devSMSProviderComputerName
    Whichever box is running the SMS Provider in Dev.
.PARAMETER prodSiteCode
    The site code of the Prod SCCM site.
.PARAMETER prodSMSProviderComputerName
    Whichever box is running the SMS Provider in Prod.
.PARAMETER configMgrPSModuleLocation
    Path to the ConfigurationManager.psd1 file, usually found in the SCCM Console install folder.
.INPUTS
    None.
.OUTPUTS
    None.
.NOTES
    Known issues:
        Set-CMTaskSequenceStepApplyOperatingSystem doesn't seem to work, even with the updated module from 1802. A bug report has been filed.
        Set-CMTaskSequenceStepInstallSoftware doesn't work using the PowerShell module from 1710. Make sure you use 1802 and above.

    Logging:
        A log file is generated and saved to C:\Windows\Temp\ in the format of: $scriptName + $timeOfExecution. Currently, logging will only detail what steps were unable to be converted. Runtime & the converted Task Sequence packageID are also at the bottom of the log.

    Details/Good to know:
        What enables this tool to be successful is when packages are named alike between the two sites. If there is content that is referenced in a Dev task sequence step that cannot be found by namesake in the Prod CM Site, the tool will not be able to set that step.

    Continuing maintenance:
        I'd like to record runtime and errors to a database rather than a flat file on disk. I might get around to adding support for this this, I might not. Additionally, there might be Task Sequence steps that reference content that the tool does not detect. If you require support for this please let me know.
        I can be reached @b_radmn
        or https://github.com/BradyDonovan/
.EXAMPLE
    .\Convert-TaskSequence_Beta.ps1 -devPackageID CM10001 -devSiteCode CM1 -devSMSProviderComputername devSCCM.server.corp -prodSiteCode CM2 -prodSMSProviderComputerName prodSCCM.server.corp -configMgrPSModuleLocation \\path\to\1802\PS\Module\ConfigurationManager.psd1
#>

[CmdletBinding()]
param
(
    [Parameter(Mandatory = $True, ValueFromPipeline = $False, HelpMessage = 'Target a Task Seqence by Package ID.')]
    [string]$devPackageID,
    [Parameter(Mandatory = $True, ValueFromPipeline = $False, HelpMessage = 'Site code of your Dev environment.')]
    [string]$devSiteCode,
    [Parameter(Mandatory = $True, ValueFromPipeline = $False, HelpMessage = 'Computer name of SMS Provider of your Dev environment.')]
    [string]$devSMSProviderComputerName,
    [Parameter(Mandatory = $True, ValueFromPipeline = $False, HelpMessage = 'Site code of your Prod environment.')]
    [string]$prodSiteCode,
    [Parameter(Mandatory = $True, ValueFromPipeline = $False, HelpMessage = 'Computer name of SMS Provider of your Prod environment.')]
    [string]$prodSMSProviderComputerName,
    [Parameter(Mandatory = $True, ValueFromPipeline = $False, HelpMessage = 'C:\path\to\folder\Containing\ConfigurationManager.psd1 (UNC paths work too)')]
    [string]$configMgrPSModuleLocation
)

##################################################
#region Load ConfigMgr PS Module
##################################################

#Set-CMTSStepInstallProgram fails to run using the PSModule from 1710, so I've had to get this going with 1802.
#That being said, I can't guarantee any level of success below 1802.
#Even then, with 1802, I've found that Set-CMTaskSequenceStepApplyOperatingSystem -InstallPackage fails.
#Bug reports have been submitted to the ConfigMgr SDK team in the meantime, so I can only hope this is fixed in the future.

#Load PSModule if it isn't loaded already.
if ($null -eq (Get-Module ConfigurationManager)) {
    Import-Module $configMgrPSModuleLocation
}

##################################################
#endregion
##################################################

##################################################
#region Define Functions
##################################################

<#
.SYNOPSIS
Log to $env:windir\Temp.

.DESCRIPTION
Logging function with severity types, so as to play nicest with CMTrace highlighting. Will log to $env:windir\Temp by default.

.PARAMETER Message
The message you want to log.

.PARAMETER MessageType
Severity level of the message you are logging.

.PARAMETER FileName
File name of the log.

.EXAMPLE
Write-Log -Message "Task failed. Reason $_" -MessageType WARNING -FileName TaskLog.log

.NOTES
Because I use this in other scripts, I dynamically generate the file name based off the following:
    $fileName = $script:MyInvocation.MyCommand.Name
    $fileName = $fileName.Replace(".ps1", "")
    $logFile = $fileName + (Get-Date -Format ddMMyyyyhhmmss) + '.log'
    Write-Log -Message "Logging start." -MessageType INFO -FileName $logFile
#>

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [Parameter(Mandatory = $true)]
        [ValidateSet("INFO", "WARNING", "ERROR")]
        [string]$MessageType,
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )
    process {
        $logPath = "$env:windir\Temp\$FileName"
        IF (Test-Path $logPath) {
            Add-Content -Path $logPath -Value ("$(Get-Date -Format HH:mm:ss) :" + "$MessageType" + ": $Message")
        }
        ELSE {
            New-Item -Path $logPath
            Add-Content -Path $logPath -Value ("$(Get-Date -Format HH:mm:ss) :" + "$MessageType" + ": $Message")
        }
    }
}

<#
.SYNOPSIS
Set PSDrives to a targeted SMS Provider.

.DESCRIPTION
Remove any PSDrives to a targeted SCCM site that you might already have, then reconnect to it with supplied credentials and set the name to the Site Code of the SCCM site.

.PARAMETER Credential
Credentials required to authenticate to the SCCM site.

.PARAMETER SiteCode
Site code of the SCCM site you wish to connect to.

.PARAMETER SMSProviderComputerName
SMS Provider computer name of the SCCM site you wish to connect to.

.EXAMPLE
Set-CMSiteProvider -Credential (Get-Credential -Message "Enter the credentials needed to authenticate to your dev SCCM server.") -SiteCode CM1 -SMSProviderComputerName devSCCM.server.corp

.NOTES
Error handling should be better but the catch I have there now is good enough for my needs.
#>

function Set-CMSiteProvider {
    [CmdletBinding()]
    param(
        [ValidateNotNull()]
        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential = [System.Management.Automation.PSCredential]::Empty,
        [Parameter(Mandatory = $True, ValueFromPipeline = $False, HelpMessage = 'Site code.')]
        [string]$SiteCode,
        [Parameter(Mandatory = $True, ValueFromPipeline = $False, HelpMessage = 'SMS Provider computer name.')]
        [string]$SMSProviderComputerName
    )

    process {

        try {

            # Site configuration from parameters.
            $global:SiteCode = "$SiteCode" # Site code
            $global:SMSProviderMachineName = "$SMSProviderComputerName" # SMS Provider machine

            #Remove any potential duplicate PSDrive
            Get-PSDrive -Name $SiteCode -ErrorAction SilentlyContinue | Remove-PSDrive -Force

            #Connect to CM Drive
            New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SMSProviderMachineName -Credential $Credential -ErrorAction Stop -Scope Global | Select-Object -ExpandProperty Name
        }

        #Throw an access denied if you can't auth to SMS Provider machine.
        catch [System.UnauthorizedAccessException] {
            throw "INFO: Access denied. Failed to authenticate to site."
        }
    }
}

##################################################
#endregion
##################################################

##################################################
#region Get Pre-Run Variables
##################################################

#Get current location. We're going to come back here when the script has finished.
$currentLoc = Get-Location

#Logging Variables
$fileName = $script:MyInvocation.MyCommand.Name
$fileName = $fileName.Replace(".ps1", "")
$logFile = $fileName + (Get-Date -Format ddMMyyyyhhmmss) + '.log'

#Setting markers for total runtime.
$counterStart = Get-Date

##################################################
#endregion
##################################################

##################################################
#region Gather credentials, switch to Dev CM Site
##################################################

$prodCred = (Get-Credential -Message "PROD\username")
$devCred = (Get-Credential -Message "DEV\username")

Set-CMSiteProvider -Credential $devCred -SiteCode $devSiteCode -SMSProviderComputerName $devSMSProviderComputerName
Set-CMSiteProvider -Credential $prodCred -SiteCode $prodSiteCode -SMSProviderComputerName $prodSMSProviderComputerName

Set-Location "$($devSiteCode):\"

##################################################
#endregion
##################################################

##################################################
#region Gather Task Sequence Step Package ID's
##################################################

#Gather the Task Sequence from dev CM site
$devTaskSequence = Get-CMTaskSequence -TaskSequencePackageId $devPackageID

#Gather Task Sequence steps
$devTaskSequenceSteps = ($devTaskSequence | Get-CMTaskSequenceStep)

##################################################
#endregion
##################################################

##################################################
#region Import TS from Dev to Prod
##################################################

#Get SMS_TaskSequencePackage object from Prod, capture to $TS so we can work with it
$TS = ([wmiclass]"\\$prodSMSProviderComputerName\root\SMS\site_$($prodSiteCode):SMS_TaskSequencePackage")

#New Task Sequence name is going to be the same name as our old Task Sequence, based off .Name property of $devTaskSequence object.
$newTSName = $devTaskSequence.Name

#Call CreateInstance method (https://msdn.microsoft.com/en-us/library/microsoft.configurationmanagement.managementprovider.connectionmanagerbase.createinstance.aspx) on SMS_TaskSequencePackage object.
$newTSInstance = $TS.CreateInstance()

#Set the new TS name.
$newTSInstance.Name = $newTSName

#Declare SMS_TaskSequence object expected by SetSequence on the following line.
$newTSSequence = $TS.ImportSequence($devTaskSequence.Sequence).TaskSequence

#Set the Task Sequence (this saves it) with expected arguments (https://docs.microsoft.com/en-us/sccm/develop/reference/osd/setsequence-method-in-class-sms_tasksequencepackage)
$newTSPackageID = $TS.SetSequence($newTSInstance, $newTSSequence).SavedTaskSequencePackagePath

#Match on the PackageID (ex: CM100001) from $newTSPackageID
$newTSPackageID = [regex]::matches($newTSPackageID, '(?<=\").+?(?=\")').value

##################################################
#endregion
##################################################

##################################################
#region Gather Task Sequence Information
##################################################

$devTSInfo = $null

#Recurse TS Steps and pull package and step information to $devTSInfo
$devTSInfo = foreach ($step in $devTaskSequenceSteps) {
    if ($step.DriverPackageID) {
        [PSCustomObject]@{
            Name      = $step.Name
            PackageID = $step.DriverPackageID
            Usage     = $step.SmsProviderObjectPath
        }
    }

    if ($step.PackageID) {
        [PSCustomObject]@{
            Name        = $step.Name
            PackageID   = $step.PackageID
            Usage       = $step.SmsProviderObjectPath
            ProgramName = $step.ProgramName
        }
    }

    if ($step.ApplicationName) {
        [PSCustomObject]@{
            Name      = $step.Name
            PackageID = $step.ApplicationName
            Usage     = $step.SmsProviderObjectPath
        }
    }

    if ($step.ImagePackageID) {
        [PSCustomObject]@{
            Name      = $step.Name
            PackageID = $step.ImagePackageID
            Usage     = $step.SmsProviderObjectPath
        }
    }
    if ($step.InstallPackageID) {
        [PSCustomObject]@{
            Name      = $step.Name
            PackageID = $step.InstallPackageID
            Usage     = $step.SmsProviderObjectPath
        }
    }
}

##################################################
#endregion
##################################################

##################################################
#region Format Application List
##################################################

#Break out the applicatons list. This needs to be handled separately.
$appList = $devTSInfo.PackageID | Select-String -Pattern "ScopeID_"

#Define all references in the TS as $allPackage
$allPackages = $devTSInfo.PackageID

#Remove any applications from $allPackages if there are any, because we already defined them in $appList.
$allPackages = $allPackages | Select-String -NotMatch $appList

##################################################
#endregion
##################################################

##################################################
#region Take PackageID & Resolve to a Name
##################################################

#Grab each TS Reference Package (in the form of CM100001, for example), query SMS Server classes for the name using $package as a parameter and store it as $packageList.
#If not found by query ($null -eq $currPackage), move to a different SMS Provider WMI class and run query.
#This gradually defines the display name for each package. We need this to later match on equally named packages in the Prod site.
$packageList = Foreach ($package in $allPackages) {
    [PSCustomObject]@{
        Type      = "SMS_DriverPackage"
        Name      = ($currPackage = (Get-WmiObject -Namespace "root\SMS\site_$devSiteCode" -ComputerName $devSMSProviderComputerName -Query "SELECT Name from SMS_DriverPackage WHERE PackageID = `"$package`"" -Credential $devCred).Name)
        PackageID = "$package"
    }

    if ($null -eq $currPackage ) {
        [PSCustomObject]@{
            Type      = "SMS_Package"
            Name      = (Get-WmiObject -Namespace "root\SMS\site_$devSiteCode" -ComputerName $devSMSProviderComputerName -Query "SELECT Name from SMS_Package WHERE PackageID = `"$package`"" -Credential $devCred).Name
            PackageID = "$package"
        }

        if ($null -eq $currPackage ) {
            [PSCustomObject]@{
                Type      = "SMS_BootImagePackage"
                Name      = (Get-WmiObject -Namespace "root\SMS\site_$devSiteCode" -ComputerName $devSMSProviderComputerName -Query "SELECT Name from SMS_BootImagePackage WHERE PackageID = `"$package`"" -Credential $devCred).Name
                PackageID = "$package"
            }

            if ($null -eq $currPackage ) {
                [PSCustomObject]@{
                    Type      = "SMS_OperatingSystemInstallPackage"
                    Name      = (Get-WmiObject -Namespace "root\SMS\site_$devSiteCode" -ComputerName $devSMSProviderComputerName -Query "SELECT Name from SMS_OperatingSystemInstallPackage WHERE PackageID = `"$package`"" -Credential $devCred).Name
                    PackageID = "$package"
                }

                if ($null -eq $currPackage) {
                    [PSCustomObject]@{
                        Type      = "SMS_ImagePackage"
                        Name      = (Get-WmiObject -Namespace "root\SMS\site_$devSiteCode" -ComputerName $devSMSProviderComputerName -Query "SELECT Name from SMS_ImagePackage WHERE PackageID = `"$package`"" -Credential $devCred).Name
                        PackageID = "$package"
                    }

                }
            }
        }
    }
    $currPackage
}

#Handling applications separately, because the query needed requires different input than the traditional package naming model, and thus would take a lot longer to finish if I used the same technique as above.
$appList = foreach ($app in $appList) {
    [PSCustomObject]@{
        Type      = "SMS_Application"
        Name      = (Get-WmiObject -Namespace "root\SMS\site_$devSiteCode" -ComputerName $devSMSProviderComputerName -Query "SELECT LocalizedDisplayName from SMS_Application WHERE ModelName = `"$app`"" -Credential $devCred).LocalizedDisplayName
        PackageID = "$app"
    }
}

#Cast $packageList again but this time without the leftover null entries from Get-WmiObject.
$packageList = ($packageList | Where-Object {$_.Name})

#Combine the two objects.
$nameWMIClassMap = ($appList + $packageList)

#Add Step Names in front $devTSInfo and recapture the object.
$stepsContainer = Foreach ($entry in $nameWMIClassMap) {
    [PSCustomObject]@{
        Type                       = $entry.Type
        PackageDisplayName         = $entry.Name
        OldPackageID               = $entry.PackageID
        TaskSequenceStepName       = $devTSInfo | Where-Object {$_.PackageID -eq $entry.PackageID} | Select-Object -ExpandProperty Name
        TaskSequenceActionWMIClass = $devTSInfo | Where-Object {$_.PackageID -eq $entry.PackageID} | Select-Object -ExpandProperty Usage
        PackageProgramUsed         = $devTSInfo | Where-Object {$_.PackageID -eq $entry.PackageID} | Select-Object -ExpandProperty ProgramName -ErrorAction SilentlyContinue #need to catch Programs if they are used, so ErrorAction is set up to prevent spammy output when there isn't a Program found
    }
}

##################################################
#endregion
##################################################

##################################################
#region Match apps in dev site to prod site
##################################################

#switch to Prod CM Site
Set-Location "$($prodSiteCode):\"

#Recurse through $stepsContainer and, depending on what type of TS Step, query the appropriate SMS Provider WMI class by the name of the content used in the step, and find a match. This creates our map between Dev & Prod content.
$appMapping = foreach ($step in $stepsContainer) {

    $currentStep = $step.TaskSequenceActionWMIClass

    switch ($currentStep) {
        SMS_TaskSequence_InstallApplicationAction {
            [PSCustomObject]@{
                Type                       = ($step.Type)
                PackageDisplayName         = ($step.PackageDisplayName)
                OldPackageID               = ($step.OldPackageID)
                NewPackageID               = ((Get-WmiObject -Namespace "root\SMS\site_$prodSiteCode" -ComputerName $prodSMSProviderComputerName -Query "SELECT ModelName from $($step.Type) WHERE LocalizedDisplayName = `"$($step.PackageDisplayName)`"").ModelName)
                TaskSequenceStepName       = ($step.TaskSequenceStepName)
                TaskSequenceActionWMIClass = ($step.TaskSequenceActionWMIClass)
                PackageProgramUsed         = ($step.PackageProgramUsed)
            }
        }
        SMS_TaskSequence_InstallSoftwareAction {
            [PSCustomObject]@{
                Type                       = ($step.Type)
                PackageDisplayName         = ($step.PackageDisplayName)
                OldPackageID               = ($step.OldPackageID)
                NewPackageID               = (Get-CMProgram -PackageName $step.PackageDisplayName -ProgramName $step.PackageProgramUsed | Select-Object -ExpandProperty PackageID) #You can't query this class in the same way you do others, so I'm leaving this here.
                TaskSequenceStepName       = ($step.TaskSequenceStepName)
                TaskSequenceActionWMIClass = ($step.TaskSequenceActionWMIClass)
                PackageProgramUsed         = ($step.PackageProgramUsed)
            }
        }
        SMS_TaskSequence_ApplyDriverPackageAction {
            [PSCustomObject]@{
                Type                       = ($step.Type)
                PackageDisplayName         = ($step.PackageDisplayName)
                OldPackageID               = ($step.OldPackageID)
                NewPackageID               = ((Get-WmiObject -Namespace "root\SMS\site_$prodSiteCode" -ComputerName $prodSMSProviderComputerName -Query "SELECT PackageID,LastRefreshTime from $($step.Type) WHERE Name = `"$($step.PackageDisplayName)`"" | Sort-Object LastRefeshTime | Select-Object -Last 1).PackageID)
                TaskSequenceStepName       = ($step.TaskSequenceStepName)
                TaskSequenceActionWMIClass = ($step.TaskSequenceActionWMIClass)
                PackageProgramUsed         = ($step.PackageProgramUsed)
            }
        }
        SMS_TaskSequence_ApplyOperatingSystemAction {
            [PSCustomObject]@{
                Type                       = ($step.Type)
                PackageDisplayName         = ($step.PackageDisplayName)
                OldPackageID               = ($step.OldPackageID)
                NewPackageID               = ((Get-WmiObject -Namespace "root\SMS\site_$prodSiteCode" -ComputerName $prodSMSProviderComputerName -Query "SELECT PackageID,LastRefreshTime from $($step.Type) WHERE Name = `"$($step.PackageDisplayName)`"" | Sort-Object LastRefeshTime | Select-Object -Last 1).PackageID)
                TaskSequenceStepName       = ($step.TaskSequenceStepName)
                TaskSequenceActionWMIClass = ($step.TaskSequenceActionWMIClass)
                PackageProgramUsed         = ($step.PackageProgramUsed)
            }
        }
        SMS_TaskSequence_UpgradeOperatingSystemAction {
            [PSCustomObject]@{
                Type                       = ($step.Type)
                PackageDisplayName         = ($step.PackageDisplayName)
                OldPackageID               = ($step.OldPackageID)
                NewPackageID               = ((Get-WmiObject -Namespace "root\SMS\site_$prodSiteCode" -ComputerName $prodSMSProviderComputerName -Query "SELECT PackageID,LastRefreshTime from $($step.Type) WHERE Name = `"$($step.PackageDisplayName)`"" | Sort-Object LastRefeshTime | Select-Object -Last 1).PackageID)
                TaskSequenceStepName       = ($step.TaskSequenceStepName)
                TaskSequenceActionWMIClass = ($step.TaskSequenceActionWMIClass)
                PackageProgramUsed         = ($step.PackageProgramUsed)
            }
        }
        SMS_TaskSequence_RunCommandLineAction {
            [PSCustomObject]@{
                Type                       = ($step.Type)
                PackageDisplayName         = ($step.PackageDisplayName)
                OldPackageID               = ($step.OldPackageID)
                NewPackageID               = ((Get-WmiObject -Namespace "root\SMS\site_$prodSiteCode" -ComputerName $prodSMSProviderComputerName -Query "SELECT PackageID,LastRefreshTime from $($step.Type) WHERE Name = `"$($step.PackageDisplayName)`"" | Sort-Object LastRefeshTime | Select-Object -Last 1).PackageID)
                TaskSequenceStepName       = ($step.TaskSequenceStepName)
                TaskSequenceActionWMIClass = ($step.TaskSequenceActionWMIClass)
                PackageProgramUsed         = ($step.PackageProgramUsed)
            }
        }
        SMS_TaskSequence_RunPowerShellScriptAction {
            [PSCustomObject]@{
                Type                       = ($step.Type)
                PackageDisplayName         = ($step.PackageDisplayName)
                OldPackageID               = ($step.OldPackageID)
                NewPackageID               = ((Get-WmiObject -Namespace "root\SMS\site_$prodSiteCode" -ComputerName $prodSMSProviderComputerName -Query "SELECT PackageID,LastRefreshTime from $($step.Type) WHERE Name = `"$($step.PackageDisplayName)`"" | Sort-Object LastRefeshTime | Select-Object -Last 1).PackageID)
                TaskSequenceStepName       = ($step.TaskSequenceStepName)
                TaskSequenceActionWMIClass = ($step.TaskSequenceActionWMIClass)
                PackageProgramUsed         = ($step.PackageProgramUsed)
            }
        }
        default { "No match was found." }
    }

}

#$testQuery = Get-WmiObject -Namespace "root\SMS\site_$prodSiteCode" -ComputerName $prodSMSProviderComputerName -Query "SELECT PackageID from SMS_DriverPackage WHERE Name = `"$($step.PackageDisplayName)`""

##################################################
#endregion
##################################################

##################################################
#region Change Prod TS Steps
##################################################

#Recurse through $appMapping now that we have NewPackageID and set each Task Sequence step to its matched package from the Prod site.
foreach ($step in $appMapping) {
    $currentStep = $step.TaskSequenceActionWMIClass
    switch ($currentStep) {
        SMS_TaskSequence_InstallApplicationAction {
            try {
                $cmApplication = Get-CMApplication -Fast -ModelName $step.NewPackageID
                Set-CMTaskSequenceStepInstallApplication -Application $cmApplication -TaskSequenceId $newTSPackageID -StepName $step.TaskSequenceStepName
            }
            catch {
                Write-Log -Message "Unable to set TS Step: `'$($step.TaskSequenceStepName)'`. Reason: $_" -MessageType WARNING -FileName $logFile
            }
        }
        SMS_TaskSequence_InstallSoftwareAction {
            try {
                $cmProgram = Get-CMProgram -PackageId $step.NewPackageID -ProgramName $step.PackageProgramUsed
                Set-CMTaskSequenceStepInstallSoftware -Program $cmProgram -TaskSequenceId $newTSPackageID -StepName $step.TaskSequenceStepName
            }
            catch {
                Write-Log -Message "Unable to set TS Step: `'$($step.TaskSequenceStepName)'`. Reason: $_" -MessageType WARNING -FileName $logFile
            }
        }
        SMS_TaskSequence_ApplyDriverPackageAction {
            try {
                Set-CMTaskSequenceStepApplyDriverPackage -PackageId $step.NewPackageID -TaskSequenceId $newTSPackageID -StepName $step.TaskSequenceStepName
            }
            catch {
                Write-Log -Message "Unable to set TS Step: `'$($step.TaskSequenceStepName)'`. Reason: $_" -MessageType WARNING -FileName $logFile
            }
        }
        SMS_TaskSequence_ApplyOperatingSystemAction {
            try {
                $cmOSImage = Get-CMOperatingSystemImage -PackageId $step.NewPackageID
                Set-CMTaskSequenceStepApplyOperatingSystem -ImagePackage $cmOSImage -ImagePackageIndex 1 -TaskSequenceId $newTSPackageID -StepName $step.TaskSequenceStepName
            }
            catch {
                Write-Log -Message "Unable to set TS Step: `'$($step.TaskSequenceStepName)'`. Reason: $_" -MessageType WARNING -FileName $logFile
            }
        }
        SMS_TaskSequence_UpgradeOperatingSystemAction {
            try {
                $cmOSInstaller = Get-CMOperatingSystemInstaller -PackageId $step.NewPackageID
                Set-CMTaskSequenceStepApplyOperatingSystem -InstallPackage $cmOSInstaller -InstallPackageIndex 1 -TaskSequenceId $newTSPackageID -StepName $step.TaskSequenceStepName #This Set cmdlet doesn't seem to be working in my environment on 1802. Filed bug report.
            }
            catch {
                Write-Log -Message "Unable to set TS Step: `'$($step.TaskSequenceStepName)'`. Reason: $_)" -MessageType WARNING -FileName $logFile
            }
        }
        SMS_TaskSequence_RunCommandLineAction {
            try {
                Set-CMTaskSequenceStepRunCommandLine -PackageId $step.NewPackageID -TaskSequenceId $newTSPackageID -StepName $step.TaskSequenceStepName
            }
            catch {
                Write-Log -Message "Unable to set TS Step: `'$($step.TaskSequenceStepName)'`. Reason: $_)" -MessageType WARNING -FileName $logFile
            }
        }
        SMS_TaskSequence_RunPowerShellScriptAction {
            try {
                Set-CMTaskSequenceStepRunPowerShellScript -PackageId $step.NewPackageID -TaskSequenceId $newTSPackageID -StepName $step.TaskSequenceStepName
            }
            catch {
                Write-Log -Message "Unable to set TS Step: `'$($step.TaskSequenceStepName)'`. Reason: $_)" -MessageType WARNING -FileName $logFile
            }
        }
    }
}


##################################################
#endregion
##################################################

##################################################
#region Finish
##################################################

[int]$runTime = (New-TimeSpan -Start ($counterStart) -End (Get-Date)).TotalMinutes
Write-Log -Message "Total runtime: $runTime minute(s)" -MessageType INFO -FileName $logFile
Write-Log -Message "Converted Task Sequence Package ID: $newTSPackageID" -MessageType INFO -FileName $logFile

Set-Location $currentLoc

##################################################
#endregion
##################################################

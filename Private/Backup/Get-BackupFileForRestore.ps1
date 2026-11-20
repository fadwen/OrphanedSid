function Get-BackupFileForRestore {
    <#
    .SYNOPSIS
    Selects the backup files in a folder that a restore of a target applies.

    .DESCRIPTION
    Reads the ObjectDN that each backup file in the folder records and selects the files of the
    target. A file name cannot identify the object: it is the sanitized distinguished name, so
    CN=User1 is a prefix of a CN_User10 backup, and the same CN recurs in every OU that holds one.

    For an organizational unit or a domain, the target is every object at or under it, and the
    restore is a bulk one. For any other object it is that object alone. Of several backups of one
    object, the most recent is selected, so two runs into one folder cannot restore an object
    twice in an arbitrary order.

    A file that cannot be read is reported with a warning and left out. A folder that holds no
    backup file, and a single object that has no backup in the folder, each end the function with
    a terminating error. So does a folder that cannot be listed, with the error of the file
    system. Invoke-RestoreWorkflow calls the function inside its try, and its catch reports each
    of them as a failed restore.

    .PARAMETER TargetObjectDN
    Distinguished name of the object, or of the container, to restore.

    .PARAMETER BackupPath
    Full path of the folder that holds the backup files. Wildcard characters are not expanded.

    .EXAMPLE
    Get-BackupFileForRestore -TargetObjectDN 'OU=Sales,DC=contoso,DC=com' -BackupPath 'C:\Backups'

    Selects the most recent backup of every object at or under the Sales unit. RestoreMode is Bulk.

    .EXAMPLE
    Get-BackupFileForRestore -TargetObjectDN 'CN=Finance,OU=Groups,DC=contoso,DC=com' -BackupPath 'C:\Backups'

    Selects the most recent backup of the Finance group. RestoreMode is Single. When the folder
    holds no backup of the group, the function ends with the error BackupNotFoundForObject.

    .INPUTS
    None.

    .OUTPUTS
    RestoreBackupSelection. An object with the properties RestoreMode, which is Single or Bulk, and
    BackupFiles, the full paths of the selected files.

    .NOTES
    AUTHOR:
    - Author: Jeffrey Stuhr
    - Blog: https://techbyjeff.net
    - LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/
    - Bluesky: https://bsky.app/profile/techbyjeff.net
    #>
    [CmdletBinding()]
    [OutputType('RestoreBackupSelection')]
    param(
        [Parameter(Mandatory)]
        [string]$TargetObjectDN,

        [Parameter(Mandatory)]
        [string]$BackupPath
    )

    # A folder that cannot be listed is not a folder with no backup in it. The files are listed
    # without -Filter and selected by their extension afterwards: with -Filter, Get-ChildItem on
    # PowerShell 7 returns nothing and reports no error for a folder that it may not read, with
    # -ErrorAction Stop as well, and on Windows PowerShell 5.1 it only writes the error.
    try {
        $allBackupFiles = @(Get-ChildItem -LiteralPath $BackupPath -File -ErrorAction Stop |
                Where-Object -Property Extension -EQ -Value '.xml')
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }

    if ($allBackupFiles.Count -eq 0) {
        $exception = [System.IO.FileNotFoundException]::new("No backup files found in directory: $BackupPath")
        $category = [System.Management.Automation.ErrorCategory]::ObjectNotFound
        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            $exception, 'BackupFilesNotFound', $category, $BackupPath)
        $PSCmdlet.ThrowTerminatingError($errorRecord)
    }

    Write-Verbose "Found $($allBackupFiles.Count) backup files in $BackupPath"

    $backupIndex = foreach ($backupFile in $allBackupFiles) {
        $backupFilePath = $backupFile.FullName
        try {
            Write-Verbose "Processing backup file: $backupFilePath"
            $backupMetadata = Import-Clixml -LiteralPath $backupFilePath -ErrorAction Stop
            [PSCustomObject]@{
                Path = $backupFilePath
                ObjectDN = [string]$backupMetadata.ObjectDN
                WrittenAt = $backupFile.LastWriteTime
            }
        } catch {
            Write-Warning "Failed to process backup file '$backupFilePath': $($_.Exception.Message)"
        }
    }
    $backupIndex = @($backupIndex | Where-Object { $_.ObjectDN })
    $ignoreCase = [System.StringComparison]::OrdinalIgnoreCase

    if ($TargetObjectDN -match '^(OU|DC)=') {
        # Every object at or under the container. The comma anchors the suffix, so OU=Sales does
        # not take in OU=PreSales.
        $restoreMode = 'Bulk'
        $inScope = @($backupIndex | Where-Object {
                $_.ObjectDN.Equals($TargetObjectDN, $ignoreCase) -or
                $_.ObjectDN.EndsWith(",$TargetObjectDN", $ignoreCase)
            })
    } else {
        # Only backups of exactly this object
        $restoreMode = 'Single'
        $inScope = @($backupIndex | Where-Object { $_.ObjectDN.Equals($TargetObjectDN, $ignoreCase) })
        if ($inScope.Count -eq 0) {
            $message = "No backup files found for object $TargetObjectDN in path $BackupPath"
            $exception = [System.IO.FileNotFoundException]::new($message)
            $category = [System.Management.Automation.ErrorCategory]::ObjectNotFound
            $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                $exception, 'BackupNotFoundForObject', $category, $TargetObjectDN)
            $PSCmdlet.ThrowTerminatingError($errorRecord)
        }
    }

    $selectedFiles = @(foreach ($group in ($inScope | Group-Object -Property { $_.ObjectDN.ToUpperInvariant() })) {
            @($group.Group | Sort-Object -Property WrittenAt -Descending)[0].Path
        })
    Write-Verbose "Matched $($selectedFiles.Count) backup files for $TargetObjectDN"

    [PSCustomObject]@{
        PSTypeName = 'RestoreBackupSelection'
        RestoreMode = $restoreMode
        BackupFiles = $selectedFiles
    }
}

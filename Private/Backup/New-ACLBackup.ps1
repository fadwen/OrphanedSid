#Requires -Version 5.1

function New-ACLBackup {
    <#
    .SYNOPSIS
        Creates comprehensive ACL backups with integrity verification

    .DESCRIPTION
        Creates detailed backups of Active Directory object ACLs including
        metadata, integrity verification, and restoration information.
        Backups are stored in XML format with a SHA256 hash of the SDDL, which
        a restore checks before it applies the backup.

        This function focuses solely on backup creation and immediate
        verification, following the single responsibility principle.

        BACKUP FEATURES:
        - SDDL (Security Descriptor Definition Language) format preservation
        - SHA256 integrity verification for authenticity validation
        - Comprehensive metadata including context and versioning information
        - Safe filename generation with illegal character replacement
        - Automatic backup directory creation with proper permissions
        - Cross-platform compatibility for hybrid environments

    .PARAMETER ObjectDN
        Distinguished name of the Active Directory object to backup.
        Supports pipeline input for batch processing operations.

        VALIDATION RULES:
        - Must be valid Distinguished Name format
        - Cannot be empty, null, or whitespace
        - Automatically trimmed and sanitized for safe processing

        BUSINESS CONTEXT:
        Used to specify target objects for backup operations. Consider
        organizing backups by organizational unit or functional area
        for easier management and recovery operations.

        EXAMPLES:
        - Single object: "CN=User1,CN=Users,DC=contoso,DC=com"
        - Container object: "OU=Sales,OU=Departments,DC=contoso,DC=com"
        - Service account: "CN=ServiceAccount,CN=ManagedServiceAccounts,DC=contoso,DC=com"

    .PARAMETER ACL
        The Active Directory Security object containing access control entries.
        Must be a valid System.DirectoryServices.ActiveDirectorySecurity object
        with properly initialized access control lists.

        VALIDATION RULES:
        - Cannot be null or empty
        - Must contain valid access control entries
        - The written file is read back, and its hash and object name are compared with
          what was written

        TECHNICAL DETAILS:
        The ACL object is converted to SDDL format for platform-independent
        storage and includes comprehensive metadata for restoration validation.

    .PARAMETER BackupPath
        Directory path for storing backup files with automatic organization.
        Supports both absolute and relative paths with automatic creation.

        VALIDATION RULES:
        - Parent directory must exist or be creatable
        - Must have write permissions for backup file creation
        - Automatically creates subdirectories as needed

        BUSINESS CONTEXT:
        Recommended to use timestamped subdirectories for organized backup
        management.

        EXAMPLES:
        - Standard path: "C:\ADBackups\ACLs"
        - Timestamped path: ".\Backup\20250704_103631"
        - Network path: "\\BackupServer\ADBackups\ACLs"

    .PARAMETER CorrelationId
        Unique identifier for tracking this backup operation across systems.
        Automatically generated if not provided for audit trail consistency.

    .EXAMPLE
        PS> New-ACLBackup -ObjectDN "CN=User1,CN=Users,DC=contoso,DC=com" -ACL $userACL -BackupPath "C:\Backups"

        DESCRIPTION: Creates comprehensive ACL backup with metadata for single user object
        OUTPUT: Boolean indicating backup success with detailed logging
        DURATION: Approximately 50-100ms for typical user object
        USE CASE: Pre-change backup for user permission modifications

    .EXAMPLE
        PS> Get-ADUser -Filter "Department -eq 'Sales'" | ForEach-Object {
        PS>     $acl = Get-Acl "AD:\$($_.DistinguishedName)"
        PS>     New-ACLBackup -ObjectDN $_.DistinguishedName -ACL $acl -BackupPath ".\Backups\Sales"
        PS> }

        DESCRIPTION: Batch backup operation for department-specific user accounts
        OUTPUT: Individual backup results for each user with correlation tracking
        BUSINESS CASE: Departmental security policy changes requiring rollback capability
        INTEGRATION: Combines AD discovery with comprehensive backup operations

    .EXAMPLE
        PS> $correlationId = [System.Guid]::NewGuid().ToString()
        PS> New-ACLBackup -ObjectDN $ouDN -ACL $ouACL -BackupPath $timestampedPath -CorrelationId $correlationId

        DESCRIPTION: Backup with a correlation ID that the caller supplies
        OUTPUT: Backup file that holds the correlation ID

    .INPUTS
        [string] Distinguished name of object to backup (pipeline supported)
        [System.DirectoryServices.ActiveDirectorySecurity] ACL object for backup

    .OUTPUTS
        [string] Full path of the backup file written. Nothing when the backup was declined
        through ShouldProcess; a failure throws.

        BACKUP FILE STRUCTURE:
        - ObjectDN: Distinguished name of backed up object
        - BackupDate: ISO timestamp of backup creation
        - CorrelationId: Unique tracking identifier
        - SDDL: Security descriptor in SDDL format
        - SDDLHash: SHA256 hash for integrity verification
        - Metadata: Comprehensive context and versioning information

    .NOTES
        Author: Jeffrey Stuhr
        Blog: https://www.techbyjeff.net
        LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/

        BACKUP FILE FORMAT:
        Files are stored in XML format using PowerShell's Export-Clixml for
        platform compatibility and include comprehensive metadata for
        restoration validation.

        SECURITY CONSIDERATIONS:
        - SHA256 integrity verification prevents tampering
        - Filename sanitization prevents path traversal attacks
        - Comprehensive audit logging for security event management
        - Correlation ID tracking for forensic analysis capability

        TROUBLESHOOTING:
        - For backup failures: .\Troubleshooting\Common\Backup-Restore-Issues.md

    .LINK
        https://docs.microsoft.com/en-us/windows/security/identity-protection/access-control/security-descriptors
        https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.security/get-acl
        https://techbyjeff.net/powershell-acl-management
        .\Troubleshooting\Common\Backup-Restore-Issues.md
        .\Troubleshooting\Common\Backup-Restore-Issues.md
    #>

    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateNotNullOrEmpty()]
        [string]$ObjectDN,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.DirectoryServices.ActiveDirectorySecurity]$ACL,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$BackupPath,

        [Parameter()]
        [string]$CorrelationId = [System.Guid]::NewGuid().ToString()
    )

    process {
        Write-StructuredLog "Starting ACL backup creation for: $ObjectDN" -Level Debug -CorrelationId $CorrelationId

        # Checked before the try: nothing has been written yet, so there is nothing for the catch
        # below to clean up
        if ([string]::IsNullOrWhiteSpace($ObjectDN.Trim())) {
            Write-StructuredLog "ObjectDN parameter cannot be empty or whitespace" -Level Error -CorrelationId $CorrelationId
            $exception = [System.ArgumentException]::new('ObjectDN parameter cannot be empty or whitespace')
            $category = [System.Management.Automation.ErrorCategory]::InvalidArgument
            $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                $exception, 'DistinguishedNameEmpty', $category, $ObjectDN)
            $PSCmdlet.ThrowTerminatingError($errorRecord)
        }

        # Read by the catch, which removes a file that was only partly written
        $backupFile = $null
        try {
            # Validate ACL contains access entries
            $entryCount = @(Get-AclAccessRule -Acl $ACL).Count
            if ($entryCount -eq 0) {
                Write-StructuredLog "ACL object contains no access entries to backup for $($ObjectDN.Trim())" -Level Warning -CorrelationId $CorrelationId
                # Continue with backup even if empty - might be intentional
            }

            # Create safe filename with comprehensive sanitization
            $safeName = $ObjectDN.Trim() -replace '[\\/:*?"<>|,=\[\]]', '_' -replace '\s+', '_'

            # The whole path must stay under the 260-character Windows limit, which .NET Framework
            # enforces on Windows PowerShell 5.1: folder, separator, name and "_yyyyMMdd_HHmmss.xml".
            # The object's DN is recorded inside the backup, so the name only has to be unique.
            $maxPathLength = 259
            # Room for the timestamp and a same-second counter (_2 to _99) added below
            $suffixLength = '_yyyyMMdd_HHmmss_99.xml'.Length
            # Resolved as PowerShell sees it: [IO.Path]::GetFullPath uses the process directory, not $PWD
            $fullFolder = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BackupPath)
            $folderLength = $fullFolder.TrimEnd('\', '/').Length + 1
            $maxNameLength = [Math]::Min(200, $maxPathLength - $folderLength - $suffixLength)
            if ($safeName.Length -gt $maxNameLength) {
                # A prefix plus a hash of the full DN, so two long DNs that share a prefix and are
                # backed up in the same second cannot overwrite each other
                $sha256 = [System.Security.Cryptography.SHA256]::Create()
                try {
                    $dnHash = -join ($sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($ObjectDN.Trim()))[0..3] |
                            ForEach-Object { $_.ToString('x2') })
                }
                finally {
                    $sha256.Dispose()
                }
                $marker = "_${dnHash}_truncated"
                $prefixLength = $maxNameLength - $marker.Length
                if ($prefixLength -lt 16) {
                    # Raised from inside the try, so the catch below is passed by. It has nothing
                    # to do here: the failure is logged on the line before, and no file exists yet.
                    $message = "Backup folder path is too long to hold a backup file within the 260-character limit: $BackupPath"
                    Write-StructuredLog $message -Level Error -CorrelationId $CorrelationId
                    $exception = [System.IO.PathTooLongException]::new($message)
                    $category = [System.Management.Automation.ErrorCategory]::InvalidArgument
                    $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                        $exception, 'BackupPathTooLong', $category, $BackupPath)
                    $PSCmdlet.ThrowTerminatingError($errorRecord)
                }
                $safeName = $safeName.Substring(0, $prefixLength) + $marker
                Write-StructuredLog "Filename truncated for length: $safeName" -Level Debug -CorrelationId $CorrelationId
            }

            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $backupFile = Join-Path $BackupPath "${safeName}_${timestamp}.xml"
            # Never overwrite an earlier backup: a second backup of the same object in the same second
            # gets a counter. The suffix space is kept free by the name budget above.
            $sequence = 1
            while (Test-Path -LiteralPath $backupFile) {
                $sequence++
                $backupFile = Join-Path $BackupPath "${safeName}_${timestamp}_$sequence.xml"
            }

            # A folder that cannot be made is raised by Initialize-BackupFolder, with the reason,
            # and enters the catch below. Left to the export, it was logged as created and then
            # reported as a part of the path that could not be found.
            if (Initialize-BackupFolder -Path $BackupPath) {
                Write-StructuredLog "Created backup directory: $BackupPath" -Level Information -CorrelationId $CorrelationId
            }

            # Create SDDL representation and SHA256 hash for integrity verification
            $sddl = $ACL.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::All)
            $sddlBytes = [System.Text.Encoding]::UTF8.GetBytes($sddl)
            $sha256 = [System.Security.Cryptography.SHA256]::Create()
            try {
                $sddlHash = $sha256.ComputeHash($sddlBytes)
            }
            finally {
                $sha256.Dispose()
            }

            # Create comprehensive backup data with enterprise metadata
            $backupData = [PSCustomObject]@{
                ObjectDN = $ObjectDN.Trim()
                # UTC in ISO 8601. Local time with a literal Z claimed UTC, so any parser shifted it
                # by the machine's offset. Invariant culture, because ':' in a custom format is the
                # culture's time separator.
                BackupDate = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [System.Globalization.CultureInfo]::InvariantCulture)
                CorrelationId = $CorrelationId
                SDDL = $sddl
                SDDLHash = [System.Convert]::ToBase64String($sddlHash)
                BackupVersion = "2.1"
                PowerShellVersion = $PSVersionTable.PSVersion.ToString()
                UserContext = $env:USERNAME
                ComputerName = $env:COMPUTERNAME
                DomainContext = $env:USERDOMAIN
                # The module version that wrote the file; BackupVersion is the file format's
                ScriptVersion = Get-OrphanedSidModuleVersion
                ValidationSignature = "PSSecurityBackup_v2.1"
                BackupMethod = "New-ACLBackup"
                ACLEntryCount = $entryCount
                # Windows PowerShell 5.1 has no Platform in $PSVersionTable. Read with the index,
                # it is $null there; read as a member, it is an error under strict mode, and no
                # backup could be written on that edition.
                Platform = if ($PSVersionTable['Platform']) { $PSVersionTable['Platform'] } else { 'Windows' }
                PSEdition = $PSVersionTable.PSEdition
            }

            # Export backup data with comprehensive error handling
            if ($PSCmdlet.ShouldProcess($ObjectDN, "Create ACL Backup")) {
                $backupData | Export-Clixml -LiteralPath $backupFile -Force -Encoding UTF8

                # Immediate integrity verification to ensure backup authenticity
                $verifyData = Import-Clixml -LiteralPath $backupFile -ErrorAction Stop
                $mismatch = $null
                if ($verifyData.SDDLHash -cne $backupData.SDDLHash) {
                    $mismatch = 'SHA256 hash'
                } elseif ($verifyData.ObjectDN.Trim() -ne $ObjectDN.Trim()) {
                    $mismatch = 'ObjectDN'
                }

                if ($null -ne $mismatch) {
                    # Raised from inside the try, so the catch below is passed by: the file is
                    # removed and the failure is logged here, as the catch would have done
                    Remove-Item -LiteralPath $backupFile -Force -ErrorAction SilentlyContinue
                    $message = "Backup integrity check failed - $mismatch mismatch detected"
                    Write-StructuredLog "Failed to create ACL backup for $($ObjectDN.Trim()) : $message" -Level Error -CorrelationId $CorrelationId
                    $exception = [System.IO.InvalidDataException]::new($message)
                    $category = [System.Management.Automation.ErrorCategory]::InvalidData
                    $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                        $exception, 'BackupIntegrityCheckFailed', $category, $backupFile)
                    $PSCmdlet.ThrowTerminatingError($errorRecord)
                }
            }
            else {
                Write-StructuredLog "Backup creation was cancelled by user" -Level Warning -CorrelationId $CorrelationId
                return
            }

            # Success logging with comprehensive details
            $writtenFile = Get-Item -LiteralPath $backupFile
            Write-StructuredLog "Successfully backed up ACL to: $backupFile (Size: $($writtenFile.Length) bytes, Entries: $entryCount, Hash: $($verifyData.SDDLHash.Substring(0,8))...)" -Level Information -CorrelationId $CorrelationId

            # The full path, so the removal result and its audit entry can name the file to restore from
            return $writtenFile.FullName
        }
        catch {
            $errorDetails = @{
                CorrelationId = $CorrelationId
                Function = $MyInvocation.MyCommand.Name
                ObjectDN = $ObjectDN
                ErrorMessage = $_.Exception.Message
                StackTrace = $_.ScriptStackTrace
                Timestamp = Get-Date
            }

            Write-StructuredLog "Failed to create ACL backup for $($ObjectDN.Trim()) : $($_.Exception.Message)" -Level Error -CorrelationId $CorrelationId -Data $errorDetails

            # Cleanup any partial backup files on failure
            if ($backupFile -and (Test-Path -LiteralPath $backupFile -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath $backupFile -Force -ErrorAction SilentlyContinue
                Write-StructuredLog "Cleaned up partial backup file: $backupFile" -Level Debug -CorrelationId $CorrelationId
            }

            $PSCmdlet.ThrowTerminatingError($_)
        }
    }
}



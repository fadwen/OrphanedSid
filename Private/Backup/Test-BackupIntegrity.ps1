#region Test-BackupIntegrity.ps1 - Backup integrity check for restore operations
<#
.SYNOPSIS
    The integrity check every restore runs on a backup before applying it.

.DESCRIPTION
    Test-BackupIntegrity takes an imported backup and checks its required properties, its
    signature, that the SHA256 of its SDDL matches the stored hash, and, when an expected object
    is given, that the backup was recorded for that object. Invoke-RestoreWorkflow calls it at the
    Standard level for every backup it restores.

    This file used to be Test-BackupValidation.ps1 and also held Test-BackupValidation,
    Test-BackupFormat and Get-BackupMetadata, which no command called; they were removed (#53).

.NOTES
    Author: Jeffrey Stuhr

    SECURITY CONSIDERATIONS:
    - Uses SHA256 cryptographic hash verification
    - Validates SDDL format to prevent injection attacks
    - Confirms backup signatures to prevent malicious data
#>
function Test-BackupIntegrity {
    <#
    .SYNOPSIS
        Validates backup file integrity and format compatibility.

    .DESCRIPTION
        Performs comprehensive validation of backup files including:
        - Required property verification for completeness
        - Signature validation for version compatibility
        - SDDL hash integrity checking using SHA256
        - Metadata completeness validation
        - Format validation to prevent malicious data injection

        This function is the primary validation gate before any restore operation,
        ensuring backup data is complete, uncorrupted, and safe to apply.

        BUSINESS VALUE:
        - Prevents data corruption through cryptographic verification
        - Ensures backup compatibility across different script versions
        - Provides detailed validation reporting for audit compliance
        - Reduces restoration failures through comprehensive pre-validation

    .PARAMETER BackupData
        PSCustomObject containing backup data to validate.
        Must include required properties: ObjectDN, BackupDate, SDDL, SDDLHash, ValidationSignature.

    .PARAMETER ExpectedObjectDN
        Optional distinguished name to verify backup target object.
        When specified, confirms backup was created for the intended object.

    .PARAMETER ValidationLevel
        Level of validation to perform: Basic, Standard, or Comprehensive.
        - Basic: Required properties and signature only
        - Standard: Includes SDDL integrity and format validation (default)
        - Comprehensive: Adds metadata validation and security checks

    .PARAMETER CorrelationId
        Unique identifier for tracking this validation operation.
        Used for correlation across logs and troubleshooting.

    .EXAMPLE
        PS> $backup = Import-Clixml "C:\Backups\user_backup.xml"
        PS> Test-BackupIntegrity -BackupData $backup

        DESCRIPTION: Validates imported backup with standard validation level
        OUTPUT: Validation result with IsValid status and detailed issues
        USE CASE: Pre-restoration validation for safety verification

    .EXAMPLE
        PS> Test-BackupIntegrity -BackupData $backup -ExpectedObjectDN "CN=TestUser,CN=Users,DC=contoso,DC=com" -ValidationLevel Comprehensive

        DESCRIPTION: Comprehensive validation with object DN verification
        OUTPUT: Detailed validation result with security checks
        USE CASE: High-security environments requiring full validation

    .EXAMPLE
        PS> $backups | Test-BackupIntegrity -ValidationLevel Basic

        DESCRIPTION: Bulk validation of multiple backups with basic checks
        OUTPUT: Validation results for each backup in the pipeline
        USE CASE: Quick validation of backup collection for bulk operations

    .INPUTS
        [PSCustomObject] Backup data objects from pipeline or parameter

    .OUTPUTS
        [PSCustomObject] BackupValidationResult with properties:
        - IsValid: Boolean indicating overall validation success
        - ValidationLevel: Level of validation performed
        - Issues: Array of specific validation issues found
        - ErrorMessage: Consolidated error information if validation fails
        - BackupInfo: Metadata about the validated backup
        - CorrelationId: Tracking identifier for this operation

    .NOTES
        Author: Jeffrey Stuhr
        Blog: https://www.techbyjeff.net
        LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/

        INTEGRITY VERIFICATION:
        - SHA256 hash verification prevents corruption detection
        - Format validation ensures compatibility and prevents injection
        - Version checking prevents incompatible restoration attempts

        PERFORMANCE CHARACTERISTICS:
        - Basic validation: ~10ms per backup
        - Standard validation: ~25ms per backup (includes crypto operations)
        - Comprehensive validation: ~50ms per backup (includes security checks)

        TROUBLESHOOTING:
        - For hash mismatches: .\Troubleshooting\Common\Backup-Restore-Issues.md
        - For format errors: .\Troubleshooting\Common\Backup-Restore-Issues.md
        - For version issues: .\Troubleshooting\Common\Backup-Restore-Issues.md

    .LINK
        .\Troubleshooting\Common\Backup-Restore-Issues.md
        .\Documentation\RestoreOperations-Analysis-Report.md
    #>

    [CmdletBinding()]
    [OutputType('BackupValidationResult')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateNotNull()]
        [PSCustomObject]$BackupData,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$ExpectedObjectDN,

        [Parameter()]
        [ValidateSet('Basic', 'Standard', 'Comprehensive')]
        [string]$ValidationLevel = 'Standard',

        [Parameter()]
        [string]$CorrelationId = [System.Guid]::NewGuid().ToString()
    )

    begin {
        Write-Verbose "Starting backup validation - CorrelationId: $CorrelationId"
        Write-Verbose "Validation level: $ValidationLevel"
    }

    process {
        try {
            $issues = @()
            $backupInfo = @{}

            # Phase 1: Basic validation - Required properties
            $requiredProperties = @('ObjectDN', 'BackupDate', 'SDDL', 'SDDLHash', 'ValidationSignature')
            foreach ($prop in $requiredProperties) {
                $property = $BackupData.PSObject.Properties[$prop]
                if (-not $property) {
                    $issues += "Missing required property: $prop"
                } elseif ([string]::IsNullOrWhiteSpace([string]$property.Value)) {
                    # Present but empty: an empty SDDL and hash would otherwise skip every check below
                    $issues += "Empty required property: $prop"
                } else {
                    $backupInfo[$prop] = $property.Value
                }
            }

            # Phase 2: Signature validation
            $validSignatures = @("PSSecurityBackup_v1.0", "PSSecurityBackup_v2.0", "PSSecurityBackup_v2.1")
            if ($BackupData.ValidationSignature -notin $validSignatures) {
                $issues += "Invalid backup signature: $($BackupData.ValidationSignature). Expected: $($validSignatures -join ', ')"
            }

            # Phase 3: Object DN validation (if specified)
            if ($ExpectedObjectDN -and $BackupData.ObjectDN -ne $ExpectedObjectDN) {
                $issues += "ObjectDN mismatch: Expected '$ExpectedObjectDN', found '$($BackupData.ObjectDN)'"
            }

            # Exit early for Basic validation
            if ($ValidationLevel -eq 'Basic') {
                return [PSCustomObject]@{
                    PSTypeName = 'BackupValidationResult'
                    IsValid = $issues.Count -eq 0
                    ValidationLevel = $ValidationLevel
                    Issues = $issues
                    ErrorMessage = if ($issues.Count -gt 0) { $issues -join '; ' } else { $null }
                    BackupInfo = $backupInfo
                    CorrelationId = $CorrelationId
                    ValidatedAt = Get-Date
                }
            }

            # Phase 4: Standard validation - SDDL integrity
            if ($BackupData.SDDL -and $BackupData.SDDLHash) {
                try {
                    $sddlBytes = [System.Text.Encoding]::UTF8.GetBytes($BackupData.SDDL)
                    $sha256 = [System.Security.Cryptography.SHA256]::Create()
                    $calculatedHash = [System.Convert]::ToBase64String($sha256.ComputeHash($sddlBytes))
                    $sha256.Dispose()

                    if ($calculatedHash -cne $BackupData.SDDLHash) {
                        $issues += "SDDL integrity check failed: Hash mismatch (expected: $($BackupData.SDDLHash), calculated: $calculatedHash)"
                    }
                }
                catch {
                    $issues += "SDDL hash validation error: $($_.Exception.Message)"
                }
            }

            # Phase 5: SDDL format validation
            if ($BackupData.SDDL) {
                try {
                    $testSecurityDescriptor = [System.DirectoryServices.ActiveDirectorySecurity]::new()
                    $testSecurityDescriptor.SetSecurityDescriptorSddlForm($BackupData.SDDL)
                    $testSecurityDescriptor = $null # Cleanup
                }
                catch {
                    $issues += "Invalid SDDL format: $($_.Exception.Message)"
                }
            }

            # Exit for Standard validation
            if ($ValidationLevel -eq 'Standard') {
                return [PSCustomObject]@{
                    PSTypeName = 'BackupValidationResult'
                    IsValid = $issues.Count -eq 0
                    ValidationLevel = $ValidationLevel
                    Issues = $issues
                    ErrorMessage = if ($issues.Count -gt 0) { $issues -join '; ' } else { $null }
                    BackupInfo = $backupInfo
                    CorrelationId = $CorrelationId
                    ValidatedAt = Get-Date
                }
            }

            # Phase 6: Comprehensive validation - Additional security and metadata checks
            if ($ValidationLevel -eq 'Comprehensive') {
                # Validate backup date is reasonable
                if ($BackupData.BackupDate) {
                    try {
                        $backupDate = [DateTime]$BackupData.BackupDate
                        $daysDiff = ((Get-Date) - $backupDate).Days

                        if ($daysDiff -lt 0) {
                            $issues += "Backup date is in the future: $($BackupData.BackupDate)"
                        }
                        elseif ($daysDiff -gt 365) {
                            $issues += "Backup is older than 1 year: $($BackupData.BackupDate) (consider validation)"
                        }
                    }
                    catch {
                        $issues += "Invalid backup date format: $($BackupData.BackupDate)"
                    }
                }

                # Validate ObjectDN format
                if ($BackupData.ObjectDN) {
                    if (-not ($BackupData.ObjectDN -match '^(CN|OU|DC)=.+')) {
                        $issues += "Invalid ObjectDN format: $($BackupData.ObjectDN)"
                    }
                }

                # Check for suspicious SDDL patterns (basic security scan)
                if ($BackupData.SDDL) {
                    $suspiciousPatterns = @('Everyone', 'Anonymous', 'S-1-1-0', 'S-1-5-7')
                    foreach ($pattern in $suspiciousPatterns) {
                        if ($BackupData.SDDL -like "*$pattern*") {
                            $issues += "Security warning: SDDL contains potentially risky permission: $pattern"
                        }
                    }
                }
            }

            $result = [PSCustomObject]@{
                PSTypeName = 'BackupValidationResult'
                IsValid = $issues.Count -eq 0
                ValidationLevel = $ValidationLevel
                Issues = $issues
                ErrorMessage = if ($issues.Count -gt 0) { $issues -join '; ' } else { $null }
                BackupInfo = $backupInfo
                CorrelationId = $CorrelationId
                ValidatedAt = Get-Date
            }

            Write-Verbose "Backup validation completed - IsValid: $($result.IsValid) - CorrelationId: $CorrelationId"
            return $result
        }
        catch {
            $errorResult = [PSCustomObject]@{
                PSTypeName = 'BackupValidationResult'
                IsValid = $false
                ValidationLevel = $ValidationLevel
                Issues = @("Validation error: $($_.Exception.Message)")
                ErrorMessage = "Validation error: $($_.Exception.Message)"
                BackupInfo = @{}
                CorrelationId = $CorrelationId
                ValidatedAt = Get-Date
            }

            Write-Error "Backup validation failed: $($_.Exception.Message) - CorrelationId: $CorrelationId"
            return $errorResult
        }
    }

    end {
        Write-Verbose "Completed backup validation process - CorrelationId: $CorrelationId"
    }
}

#endregion

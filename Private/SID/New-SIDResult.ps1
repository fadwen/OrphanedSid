#Requires -Version 5.1

#region SID Result Factory Functions

function New-OrphanedSIDResult {
    <#
    .SYNOPSIS
        Creates comprehensive OrphanedSIDResult objects with full metadata

    .DESCRIPTION
        Factory function that creates properly structured OrphanedSIDResult objects
        with all required properties, comprehensive metadata, and validation. This
        function ensures consistent result object creation across the entire solution.

        The function provides:
        - Complete property population with safe access rule extraction
        - Rich metadata including correlation IDs and processing timestamps
        - Comprehensive validation of input parameters and created objects
        - Support for different processing methods and analysis confidence levels

    .PARAMETER ObjectDN
        Distinguished name of the Active Directory object containing the orphaned SID.
        This provides context for where the orphaned SID was discovered.

    .PARAMETER ObjectClass
        Class of the AD object (user, group, computer, organizationalUnit, etc.)
        for categorization and analysis context.

    .PARAMETER OrphanedSID
        The orphaned Security Identifier string that was detected.
        Must be a valid SID format.

    .PARAMETER AccessRule
        The access rule object containing the orphaned SID. Used to extract
        detailed ACL information including rights, inheritance, and object types.

    .PARAMETER LikelySource
        Categorized source of the orphaned SID based on analysis.
        Examples: "Deleted User", "Moved Account", "Unknown Domain", etc.

    .PARAMETER Confidence
        Analysis confidence level indicating the reliability of the source categorization.
        Values: "High", "Medium", "Low"

    .PARAMETER Notes
        Detailed analysis notes providing additional context and recommendations
        for the orphaned SID.

    .PARAMETER ProcessingMethod
        Method used to detect the orphaned SID for audit and troubleshooting purposes.
        Examples: "Enhanced-ACL-Retrieval", "Identity-Resolution", "NTAccount-Translation-Failed"

    .PARAMETER VerificationStatus
        Orphaned (default) when every lookup completed and none found the SID; Unverified when a
        lookup failed, so the SID may still belong to a live principal. Unverified results are
        reported for re-checking and are never removed.

    .PARAMETER VerificationError
        For Unverified results, the lookup failures that prevented a verdict.

    .PARAMETER CorrelationId
        Unique identifier for tracking this operation across logs and audit trails.
        Generated automatically if not provided.

    .EXAMPLE
        PS> $result = New-OrphanedSIDResult -ObjectDN $dn -OrphanedSID $sid -AccessRule $rule

        DESCRIPTION: Basic orphaned SID result creation with minimal parameters
        OUTPUT: Complete OrphanedSIDResult object with auto-generated metadata
        USE CASE: Standard orphaned SID result creation in processing workflows

    .EXAMPLE
        PS> $result = New-OrphanedSIDResult -ObjectDN $dn -ObjectClass "User" -OrphanedSID $sid -AccessRule $rule -LikelySource "Deleted User" -Confidence "High" -Notes "Account was deleted 30 days ago"

        DESCRIPTION: Comprehensive result creation with full analysis metadata
        OUTPUT: Rich OrphanedSIDResult object with detailed analysis information
        BUSINESS CASE: Complete audit trail with high-confidence analysis

    .EXAMPLE
        PS> $result = New-OrphanedSIDResult -ObjectDN $dn -OrphanedSID $sid -AccessRule $rule -ProcessingMethod "NTAccount-Translation-Failed" -CorrelationId $correlationId

        DESCRIPTION: Result creation with specific processing method and correlation tracking
        OUTPUT: OrphanedSIDResult with audit trail correlation and processing context

    .OUTPUTS
        [OrphanedSIDResult] Fully populated result object containing:
        - Object identification (DN, class, timestamp)
        - Orphaned SID details (SID, source analysis, confidence)
        - ACL information (access control type, rights, inheritance)
        - Processing metadata (correlation ID, method, timestamp)
        - Analysis details (notes, recommendations, confidence level)

    .NOTES
        OBJECT CREATION PROCESS:
        1. Validate input parameters and SID format
        2. Create new OrphanedSIDResult object instance
        3. Populate core object identification properties
        4. Extract and set ACL metadata safely
        5. Add comprehensive processing metadata
        6. Validate completed object structure

        METADATA CATEGORIES:
        - Object Context: DN, class, discovery timestamp
        - SID Analysis: Orphaned SID, source, confidence level
        - ACL Details: Access rights, control type, inheritance
        - Processing Info: Method, correlation ID, action taken

        ERROR HANDLING:
        - Comprehensive input validation with detailed error messages
        - Safe property extraction with null checking
        - Graceful handling of missing or invalid access rule properties
        - Detailed logging for troubleshooting and audit purposes

        TROUBLESHOOTING:
        - For result creation issues: .\Troubleshooting\Common\Result-Creation-Issues.md
        - For metadata population errors: .\Troubleshooting\Common\Metadata-Population-Issues.md
        - For object validation problems: .\Troubleshooting\Common\Result-Validation-Issues.md
    #>

    [CmdletBinding()]
    [OutputType([OrphanedSIDResult])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'This is a factory function that creates objects but does not change system state')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ObjectDN,

        [Parameter()]
        [string]$ObjectClass = "Unknown",

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$OrphanedSID,

        [Parameter(Mandatory)]
        [PSObject]$AccessRule,

        [Parameter()]
        [string]$LikelySource = "Unknown",

        [Parameter()]
        [ValidateSet("High", "Medium", "Low")]
        [string]$Confidence = "Medium",

        [Parameter()]
        [string]$Notes = "",

        [Parameter()]
        [string]$ProcessingMethod = "Standard",

        [Parameter()]
        [ValidateSet('Orphaned', 'Unverified')]
        [string]$VerificationStatus = 'Orphaned',

        [Parameter()]
        [string]$VerificationError,

        [Parameter()]
        [string]$CorrelationId = [System.Guid]::NewGuid().ToString()
    )

    Write-StructuredLog "Creating OrphanedSIDResult object for $ObjectDN" -Level Debug -CorrelationId $CorrelationId

    # Validate OrphanedSID format. Checked before the try, with the log entry and the message that
    # the catch below gives an error of a step: raised inside the try, the error would pass that
    # catch by.
    if (-not (Test-SIDFormat -SID $OrphanedSID -CorrelationId $CorrelationId)) {
        $reason = "Invalid SID format provided: $OrphanedSID"
        Write-StructuredLog "Error creating OrphanedSIDResult object for $ObjectDN : $reason" -Level Error -CorrelationId $CorrelationId
        $exception = [System.ArgumentException]::new("Failed to create OrphanedSIDResult: $reason")
        $category = [System.Management.Automation.ErrorCategory]::InvalidArgument
        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            $exception, 'SidFormatInvalid', $category, $OrphanedSID)
        $PSCmdlet.ThrowTerminatingError($errorRecord)
    }

    try {
        # Create new result object instance
        $result = [OrphanedSIDResult]::new()

        # Set core object identification properties
        $result.ObjectDN = $ObjectDN.Trim()
        $result.ObjectClass = $ObjectClass
        $result.OrphanedSID = $OrphanedSID
        $result.LikelySource = $LikelySource
        $result.Confidence = $Confidence
        $result.AnalysisNotes = $Notes
        $result.VerificationStatus = $VerificationStatus
        $result.VerificationError = $VerificationError

        # Add processing metadata
        Add-ProcessingMetadata -Result $result -ProcessingMethod $ProcessingMethod -CorrelationId $CorrelationId

        # Extract and set ACL metadata safely
        Set-ACLMetadata -Result $result -AccessRule $AccessRule -CorrelationId $CorrelationId

        Write-StructuredLog "Successfully created OrphanedSIDResult object for $ObjectDN with SID $OrphanedSID" -Level Debug -CorrelationId $CorrelationId

        return $result
    }
    catch {
        Write-StructuredLog "Error creating OrphanedSIDResult object for $ObjectDN : $($_.Exception.Message)" -Level Error -CorrelationId $CorrelationId
        $message = "Failed to create OrphanedSIDResult: $($_.Exception.Message)"
        $exception = [System.InvalidOperationException]::new($message, $_.Exception)
        $category = [System.Management.Automation.ErrorCategory]::InvalidOperation
        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            $exception, 'SidResultNotCreated', $category, $ObjectDN)
        $PSCmdlet.ThrowTerminatingError($errorRecord)
    }
}

function Add-ProcessingMetadata {
    <#
    .SYNOPSIS
        Adds comprehensive processing metadata to result objects

    .DESCRIPTION
        Populates result objects with detailed processing metadata including
        correlation IDs, timestamps, processing methods, and audit information.
        This function ensures consistent metadata across all result objects.

    .PARAMETER Result
        The OrphanedSIDResult object to populate with metadata

    .PARAMETER ProcessingMethod
        Method used to detect the orphaned SID

    .PARAMETER CorrelationId
        Unique identifier for tracking this operation

    .NOTES
        METADATA ADDED:
        - Processing method and timestamp
        - Correlation ID for audit trails
        - Action taken and operator context
        - System and environment information
    #>

    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Metadata is a mass noun; the name is shared with the tests and docs')]
    param(
        [Parameter(Mandatory)]
        [OrphanedSIDResult]$Result,

        [Parameter()]
        [string]$ProcessingMethod = "Standard",

        [Parameter()]
        [string]$CorrelationId = [System.Guid]::NewGuid().ToString()
    )

    try {
        Write-StructuredLog "Adding processing metadata to result object" -Level Debug -CorrelationId $CorrelationId

        # Core processing metadata
        $Result.ProcessingMethod = $ProcessingMethod
        $Result.ActionTaken = "Detected"
        $Result.CorrelationId = $CorrelationId
        $Result.Timestamp = Get-Date

        # Additional context metadata
        if (-not $Result.PSObject.Properties['ProcessingContext']) {
            $Result | Add-Member -NotePropertyName 'ProcessingContext' -NotePropertyValue @{
                MachineName = $env:COMPUTERNAME
                UserName = $env:USERNAME
                ProcessId = $PID
                PowerShellVersion = $PSVersionTable.PSVersion.ToString()
                ModuleVersion = Get-OrphanedSidModuleVersion
            }
        }

        Write-StructuredLog "Successfully added processing metadata with correlation ID $CorrelationId" -Level Debug -CorrelationId $CorrelationId
    }
    catch {
        Write-StructuredLog "Error adding processing metadata: $($_.Exception.Message)" -Level Warning -CorrelationId $CorrelationId
        $PSCmdlet.ThrowTerminatingError($_)
    }
}

function Set-ACLMetadata {
    <#
    .SYNOPSIS
        Safely extracts and sets ACL metadata from access rules

    .DESCRIPTION
        Performs safe extraction of ACL properties from access rule objects,
        handling missing properties and null values gracefully. This function
        ensures comprehensive ACL metadata is captured for audit and analysis.

    .PARAMETER Result
        The OrphanedSIDResult object to populate with ACL metadata

    .PARAMETER AccessRule
        The access rule object to extract metadata from

    .PARAMETER CorrelationId
        Unique identifier for tracking this operation

    .NOTES
        ACL METADATA EXTRACTED:
        - Access control type (Allow/Deny)
        - Active Directory rights and permissions
        - Inheritance flags and object types
        - Object GUIDs for extended rights
        - Inheritance hierarchy information

        ERROR HANDLING:
        - Safe property access with null checking
        - Graceful handling of missing properties
        - Default values for unavailable metadata
        - Comprehensive logging for troubleshooting
    #>

    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Metadata is a mass noun; the name is shared with the tests and docs')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Populates properties on the result object passed in, nothing on the system')]
    param(
        [Parameter(Mandatory)]
        [OrphanedSIDResult]$Result,

        [Parameter(Mandatory)]
        [PSObject]$AccessRule,

        [Parameter()]
        [string]$CorrelationId = [System.Guid]::NewGuid().ToString()
    )

    try {
        Write-StructuredLog "Extracting ACL metadata from access rule" -Level Debug -CorrelationId $CorrelationId

        # Extract access control type safely
        if ($AccessRule.PSObject.Properties['AccessControlType']) {
            $Result.AccessControlType = $AccessRule.AccessControlType
            Write-StructuredLog "Set AccessControlType: $($Result.AccessControlType)" -Level Debug -CorrelationId $CorrelationId
        } else {
            $Result.AccessControlType = [System.Security.AccessControl.AccessControlType]::Allow
            Write-StructuredLog "AccessControlType property missing, set to Allow" -Level Debug -CorrelationId $CorrelationId
        }

        # Extract Active Directory rights safely
        if ($AccessRule.PSObject.Properties['ActiveDirectoryRights']) {
            $Result.ActiveDirectoryRights = $AccessRule.ActiveDirectoryRights
            Write-StructuredLog "Set ActiveDirectoryRights: $($Result.ActiveDirectoryRights)" -Level Debug -CorrelationId $CorrelationId
        } else {
            # Try alternative property names
            if ($AccessRule.PSObject.Properties['Rights']) {
                $Result.ActiveDirectoryRights = $AccessRule.Rights
                Write-StructuredLog "Set ActiveDirectoryRights from Rights property: $($Result.ActiveDirectoryRights)" -Level Debug -CorrelationId $CorrelationId
            } else {
                $Result.ActiveDirectoryRights = [System.DirectoryServices.ActiveDirectoryRights]::GenericRead
                Write-StructuredLog "ActiveDirectoryRights property missing, set to GenericRead" -Level Debug -CorrelationId $CorrelationId
            }
        }

        # Extract inheritance information safely
        if ($AccessRule.PSObject.Properties['InheritanceFlags']) {
            $Result.InheritanceType = $AccessRule.InheritanceFlags
            Write-StructuredLog "Set InheritanceType: $($Result.InheritanceType)" -Level Debug -CorrelationId $CorrelationId
        } else {
            $Result.InheritanceType = [System.Security.AccessControl.InheritanceFlags]::None
            Write-StructuredLog "InheritanceFlags property missing, set to None" -Level Debug -CorrelationId $CorrelationId
        }

        # Handle ObjectType GUID safely
        $Result.ObjectType = Get-SafeGuidProperty -Object $AccessRule -PropertyName 'ObjectType' -CorrelationId $CorrelationId

        # Handle InheritedObjectType GUID safely
        $Result.InheritedObjectType = Get-SafeGuidProperty -Object $AccessRule -PropertyName 'InheritedObjectType' -CorrelationId $CorrelationId

        # Extract inheritance status safely
        if ($AccessRule.PSObject.Properties['IsInherited']) {
            $Result.IsInherited = $AccessRule.IsInherited
            Write-StructuredLog "Set IsInherited: $($Result.IsInherited)" -Level Debug -CorrelationId $CorrelationId
        } else {
            $Result.IsInherited = $false
            Write-StructuredLog "IsInherited property missing, set to false" -Level Debug -CorrelationId $CorrelationId
        }

        Write-StructuredLog "Successfully extracted all available ACL metadata" -Level Debug -CorrelationId $CorrelationId
    }
    catch {
        Write-StructuredLog "Error extracting ACL metadata: $($_.Exception.Message)" -Level Warning -CorrelationId $CorrelationId
        $PSCmdlet.ThrowTerminatingError($_)
    }
}

function Get-SafeGuidProperty {
    <#
    .SYNOPSIS
        Safely extracts GUID properties from objects with proper null handling

    .DESCRIPTION
        Handles the safe extraction of GUID properties from various object types,
        including proper handling of null values, empty GUIDs, and missing properties.

    .PARAMETER Object
        The object to extract the GUID property from

    .PARAMETER PropertyName
        Name of the GUID property to extract

    .PARAMETER CorrelationId
        Unique identifier for tracking this operation

    .OUTPUTS
        [System.Guid] The extracted GUID or Empty GUID if not available

    .NOTES
        GUID HANDLING:
        - Returns actual GUID if property exists and has value
        - Returns Empty GUID for null or missing properties
        - Handles various GUID string formats
        - Provides comprehensive error handling
    #>

    [CmdletBinding()]
    [OutputType([System.Guid])]
    param(
        [Parameter(Mandatory)]
        [PSObject]$Object,

        [Parameter(Mandatory)]
        [string]$PropertyName,

        [Parameter()]
        [string]$CorrelationId = [System.Guid]::NewGuid().ToString()
    )

    try {
        if ($Object.PSObject.Properties[$PropertyName] -and $Object.$PropertyName) {
            $guidValue = $Object.$PropertyName

            # Handle different GUID formats
            if ($guidValue -is [System.Guid]) {
                if ($guidValue -eq [System.Guid]::Empty) {
                    Write-StructuredLog "GUID property $PropertyName is empty GUID" -Level Debug -CorrelationId $CorrelationId
                    return [System.Guid]::Empty
                } else {
                    Write-StructuredLog "Set $PropertyName to GUID: $guidValue" -Level Debug -CorrelationId $CorrelationId
                    return $guidValue
                }
            } elseif ($guidValue -is [string]) {
                if ([string]::IsNullOrWhiteSpace($guidValue) -or $guidValue -eq "00000000-0000-0000-0000-000000000000") {
                    Write-StructuredLog "GUID property $PropertyName is empty string or zero GUID" -Level Debug -CorrelationId $CorrelationId
                    return [System.Guid]::Empty
                } else {
                    try {
                        $parsedGuid = [System.Guid]::Parse($guidValue)
                        Write-StructuredLog "Set $PropertyName to parsed GUID: $parsedGuid" -Level Debug -CorrelationId $CorrelationId
                        return $parsedGuid
                    } catch {
                        Write-StructuredLog "Failed to parse GUID string for $PropertyName : $guidValue" -Level Debug -CorrelationId $CorrelationId
                        return [System.Guid]::Empty
                    }
                }
            } else {
                Write-StructuredLog "GUID property $PropertyName has unexpected type: $($guidValue.GetType().Name)" -Level Debug -CorrelationId $CorrelationId
                return [System.Guid]::Empty
            }
        } else {
            Write-StructuredLog "GUID property $PropertyName missing or null, set to Empty" -Level Debug -CorrelationId $CorrelationId
            return [System.Guid]::Empty
        }
    }
    catch {
        Write-StructuredLog "Error extracting GUID property $PropertyName : $($_.Exception.Message)" -Level Warning -CorrelationId $CorrelationId
        return [System.Guid]::Empty
    }
}

#endregion

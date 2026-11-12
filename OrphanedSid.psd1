@{
    RootModule = 'OrphanedSid.psm1'
    ModuleVersion = '1.1.0'
    GUID = '7d3f2a9e-5b61-4c08-9e4a-2f8c1b6d0a37'
    Author = 'Jeffrey Stuhr'
    CompanyName = 'Jeffrey Stuhr'
    Copyright = '(c) 2026 Jeffrey Stuhr. All rights reserved.'
    Description = 'Finds orphaned SIDs in Active Directory ACLs, removes them with a backup of every ACL it touches, and restores an ACL from that backup'

    # Windows PowerShell 5.1 is a real target: the RSAT ActiveDirectory module ships for it and
    # most domain-joined management hosts have nothing else installed.
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    # The ActiveDirectory module is Windows-only RSAT and is not on the Gallery, so it is checked
    # at run time by each command rather than declared here. Declaring it would make the module
    # unimportable, and the test suite unrunnable, on any host without RSAT.
    RequiredModules = @()

    FunctionsToExport = @(
        'Find-OrphanedSid'
        'Remove-OrphanedSid'
        'Restore-OrphanedSidBackup'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()

    PrivateData = @{
        PSData = @{
            Tags = @(
                'ActiveDirectory', 'AD', 'SID', 'OrphanedSID', 'ACL', 'Security', 'Permissions',
                'Cleanup', 'Audit', 'Compliance', 'Backup', 'Restore',
                'PSEdition_Desktop', 'PSEdition_Core', 'Windows'
            )
            LicenseUri = 'https://github.com/fadwen/OrphanedSid/blob/main/LICENSE'
            ProjectUri = 'https://github.com/fadwen/OrphanedSid'
            ReleaseNotes = @'
1.1.0 - Safer removal, faster detection, and fixes from testing against a live domain.
A SID is reported orphaned only when its deleted object is found or every directory lookup
completed and none found it. A SID whose lookup failed, including one from a trusted domain that
cannot be reached, is reported as Unverified (new VerificationStatus and VerificationError
properties) and is never removed. A live principal found among deleted-object search results is no
longer taken as deleted.
Remove-OrphanedSid takes one backup per object, removes all of that object's orphaned entries
together, and returns one RemovalOperationResult per object; restoring such an object now brings
back every removed entry. Inherited entries are left in place with a warning.
Detection is several times faster: on a lab domain controller a typical user object went from
941 ms to 96 ms on Windows PowerShell 5.1. An unreachable domain controller costs about 42 seconds
per SID instead of 3.5 minutes.
Pipeline input of Active Directory objects now works for all three commands. -MaxRetries now
sets the retries of each search-base read and SID lookup. Logging, configuration, backup
timestamps, correlation IDs and restore messages are corrected.
See CHANGELOG.md for every change and the issue behind it.
'@
            RequireLicenseAcceptance = $false
        }
    }
}

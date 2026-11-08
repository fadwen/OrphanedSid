@{
    RootModule = 'OrphanedSid.psm1'
    ModuleVersion = '1.0.0'
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
1.0.0 - First release as a module.
Find-OrphanedSid, Remove-OrphanedSid and Restore-OrphanedSidBackup replace the three modes of the
Find-UnknownSID.ps1 script that lived in the TechbyJeff repository. Results are written to the
pipeline as objects; -OutputPath still writes a CSV. Remove-OrphanedSid and
Restore-OrphanedSidBackup prompt before changing anything and need -Force (or -Confirm:$false)
to run unattended.
See CHANGELOG.md for the detail.
'@
            RequireLicenseAcceptance = $false
        }
    }
}

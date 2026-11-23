@{
    RootModule = 'OrphanedSid.psm1'
    ModuleVersion = '1.2.0'
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
1.2.0 - Objects that were reported and could not be cleaned, removal results that say what
happened, and critical errors with error IDs of their own.
Objects that Find-OrphanedSid reported and Remove-OrphanedSid could not reach are now cleaned and
restored: a name with [ ] * ? or a backtick, a name with & ; | or %, an object that is named by an
attribute other than CN, OU or DC, and, on Windows PowerShell 5.1, a name with a comma or another
character that Active Directory escapes. The root of a single-label domain is accepted as a
search base. A path with square brackets works for -BackupPath, -LogPath, -OutputPath and
-ConfigPath.
A removal result is Success = False when an entry that discovery reported is no longer on the
object and when every entry failed to be removed, and a hosted PowerShell 7 runspace no longer
reports a success with nothing removed. The new NotFoundSIDs property lists the entries that were
not found.
Restore-OrphanedSidBackup has a -BackupFile parameter for one object from one named file, writes
security entries to the log, and finds the backup of a target that is typed with blanks after its
commas.
Critical errors have error IDs of their own, such as ActiveDirectoryModuleMissing and
ConfigurationFileNotLoaded, and a start-up failure ends the command whatever the error action is.
A -ConfigPath file that is gone when the run starts ends the run. Importing the module fails when
one of its files does not load.
A directory server that cannot be contacted no longer costs a connect timeout for every SID. The
times in the log are text with the offset from UTC on both editions. A log detail that is named
as a secret is written as [REDACTED]. The module runs under strict mode.
Automation that matches an error ID, the text of an error, the Success of a removal or the form
of a time in the log should read the Changed section of CHANGELOG.md first.
See CHANGELOG.md for every change and the issue behind it.
'@
            RequireLicenseAcceptance = $false
        }
    }
}

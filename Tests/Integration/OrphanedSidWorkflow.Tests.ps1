#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
<#
.SYNOPSIS
    End-to-end tests of the three public commands against an in-memory directory.

.DESCRIPTION
    Imports the module and runs Find-OrphanedSid, Remove-OrphanedSid and Restore-OrphanedSidBackup
    exactly as an operator would. Only the boundary is mocked: the ActiveDirectory cmdlets and
    Get-Acl/Set-Acl on AD:\ paths read and write a hashtable of objects whose security descriptors
    are real ActiveDirectorySecurity instances held as SDDL. Nothing inside the module is mocked.
    Every assertion is made on what
    the commands return, what they leave in that directory, and what they write to disk.

    The directory holds four kinds of trustee:
    - BUILTIN\Administrators, which is protected and never reported.
    - A live domain user, found by the SID lookup.
    - An orphaned domain SID, which every lookup reports as not found.
    - A domain SID whose lookups fail with an access-denied error, which must be reported as
      unverified and never removed (issue #9).

.NOTES
    Author: Jeffrey Stuhr
    Blog: https://www.techbyjeff.net
    LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/
#>

BeforeAll {
    . "$PSScriptRoot\..\TestHelpers\ADCmdletStubs.ps1"

    # The Access property on ObjectSecurity is added by this module's type data
    Import-Module Microsoft.PowerShell.Security

    if (-not (Get-Module -Name OrphanedSid)) {
        Import-Module "$PSScriptRoot\..\..\OrphanedSid.psd1"
    }

    $script:DomainSid = 'S-1-5-21-1111111111-2222222222-3333333333'
    $script:DomainDN = 'DC=lab,DC=test'
    $script:LiveSid = "$script:DomainSid-1105"
    $script:OrphanSid = "$script:DomainSid-1999"
    $script:SecondOrphanSid = "$script:DomainSid-1998"
    $script:FailingSid = "$script:DomainSid-1777"
    # A live principal whose ordinary lookups time out; only the deleted-objects lookup answers (#39)
    $script:FlakySid = "$script:DomainSid-1300"
    # A deleted principal whose lookups time out the next $script:TransientFailures times, then
    # answer not-found; used to show that -MaxRetries reaches the lookups (#89)
    $script:TransientSid = "$script:DomainSid-1400"
    $script:TransientFailures = 0
    $script:BuiltinAdmins = 'S-1-5-32-544'

    function New-DirectoryObject {
        param([string]$DN, [string]$ObjectClass, [string[]]$Trustee)
        $aces = foreach ($sid in $Trustee) { "(A;;RPWP;;;$sid)" }
        @{ ObjectClass = $ObjectClass; Sddl = "O:BAG:BAD:(A;;GA;;;BA)$($aces -join '')" }
    }

    function Reset-Directory {
        param([int]$ExtraObjects = 0)
        $script:Directory = [ordered]@{}
        $script:Directory["OU=Finance,$script:DomainDN"] =
            New-DirectoryObject -DN "OU=Finance,$script:DomainDN" -ObjectClass 'organizationalUnit' -Trustee $script:LiveSid, $script:OrphanSid
        $script:Directory["CN=Payroll,OU=Finance,$script:DomainDN"] =
            New-DirectoryObject -DN "CN=Payroll,OU=Finance,$script:DomainDN" -ObjectClass 'group' -Trustee $script:OrphanSid, $script:FailingSid
        $script:Directory["CN=Clean,OU=Finance,$script:DomainDN"] =
            New-DirectoryObject -DN "CN=Clean,OU=Finance,$script:DomainDN" -ObjectClass 'group' -Trustee $script:LiveSid
        for ($i = 1; $i -le $ExtraObjects; $i++) {
            $dn = "CN=Bulk$i,OU=Finance,$script:DomainDN"
            $script:Directory[$dn] = New-DirectoryObject -DN $dn -ObjectClass 'group' -Trustee $script:LiveSid, $script:OrphanSid
        }
        $script:OriginalSddl = @{}
        foreach ($dn in $script:Directory.Keys) {
            $script:OriginalSddl[$dn] = $script:Directory[$dn].Sddl
        }
    }

    function Get-DirectoryAcl {
        param([string]$DN)
        $acl = [System.DirectoryServices.ActiveDirectorySecurity]::new()
        $acl.SetSecurityDescriptorSddlForm($script:Directory[$DN].Sddl)
        $acl
    }

    function Get-TrusteeSid {
        param([string]$DN)
        $acl = Get-DirectoryAcl -DN $DN
        @($acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]) |
            ForEach-Object { $_.IdentityReference.Value })
    }

    function Get-SidFromFilter {
        param([string]$Filter)
        if ($Filter -match "(?i)(objectSid|SID) -eq '([^']+)'") { return $Matches[2] }
    }

    # A lookup by SID: the live SID is found, the failing SID throws access denied, anything else
    # is not there. Mirrors what each AD cmdlet returns for a -Filter query.
    function Invoke-SidLookup {
        param([string]$Sid)
        if ($Sid -eq $script:FailingSid) {
            throw [System.UnauthorizedAccessException]::new('Access is denied.')
        }
        if ($Sid -eq $script:FlakySid) {
            throw [System.TimeoutException]::new('The operation returned because the timeout limit was exceeded.')
        }
        if ($Sid -eq $script:TransientSid -and $script:TransientFailures -gt 0) {
            $script:TransientFailures--
            throw [System.TimeoutException]::new('The operation returned because the timeout limit was exceeded.')
        }
        if ($Sid -eq $script:LiveSid) {
            return [PSCustomObject]@{ DistinguishedName = "CN=Alice,OU=Users,$script:DomainDN"; ObjectClass = 'user'; SID = $Sid }
        }
        return $null
    }

    # Every correlation ID a log line carries: the bracketed field of a text line and the
    # CorrelationId of a JSON line
    function Get-LogCorrelationId {
        param([string]$Path)
        foreach ($line in Get-Content -Path $Path) {
            if ($line -match '^\[[^\]]+\] \[[^\]]+\] \[[^\]]+\] \[([^\]]+)\]') { $Matches[1] }
            elseif ($line -match '"CorrelationId":"([^"]+)"') { $Matches[1] }
        }
    }

    function Invoke-FindOrphanedSid {
        param([string]$OutputPath, [int]$MaxRetries = -1)
        $parameters = @{
            SearchBase            = "OU=Finance,$script:DomainDN"
            LogPath               = Join-Path $TestDrive 'find.log'
            SuppressConsoleOutput = $true
        }
        if ($OutputPath) { $parameters.OutputPath = $OutputPath }
        if ($MaxRetries -ge 0) { $parameters.MaxRetries = $MaxRetries }
        Find-OrphanedSid @parameters
    }

    function Invoke-RemoveOrphanedSid {
        param([switch]$WhatIf, [switch]$IncludeInherited)
        $parameters = @{
            SearchBase            = "OU=Finance,$script:DomainDN"
            BackupPath            = $script:BackupRoot
            LogPath               = Join-Path $TestDrive 'remove.log'
            SuppressConsoleOutput = $true
            Force                 = $true
            WhatIf                = $WhatIf
            IncludeInherited      = $IncludeInherited
        }
        Remove-OrphanedSid @parameters
    }
}

Describe 'OrphanedSid end to end' -Tag 'Integration' {
    BeforeAll {
        Mock -ModuleName OrphanedSid Get-Module { [PSCustomObject]@{ Name = 'ActiveDirectory' } } -ParameterFilter { $Name -eq 'ActiveDirectory' }
        Mock -ModuleName OrphanedSid Import-Module { } -ParameterFilter { $Name -eq 'ActiveDirectory' }

        Mock -ModuleName OrphanedSid Get-ADDomain {
            [PSCustomObject]@{
                DistinguishedName = $script:DomainDN
                DomainSID         = [System.Security.Principal.SecurityIdentifier]::new($script:DomainSid)
            }
        }

        Mock -ModuleName OrphanedSid Get-ADObject {
            if ($SearchBase) {
                foreach ($dn in @($script:Directory.Keys)) {
                    # Not -like: a search base is a name, and one with a backtick or a bracket would
                    # be read as a pattern
                    if ($dn.EndsWith([string]$SearchBase, [System.StringComparison]::OrdinalIgnoreCase)) {
                        [PSCustomObject]@{
                            DistinguishedName    = $dn
                            Name                 = ($dn -split ',')[0] -replace '^\w+='
                            ObjectClass          = $script:Directory[$dn].ObjectClass
                            nTSecurityDescriptor = Get-DirectoryAcl -DN $dn
                        }
                    }
                }
                return
            }
            if ($Identity) {
                if ($script:Directory.Contains([string]$Identity)) {
                    return [PSCustomObject]@{
                        DistinguishedName    = [string]$Identity
                        ObjectClass          = $script:Directory[[string]$Identity].ObjectClass
                        nTSecurityDescriptor = Get-DirectoryAcl -DN ([string]$Identity)
                    }
                }
                throw "Directory object not found: $Identity"
            }
            $sid = Get-SidFromFilter -Filter $Filter
            # Like Active Directory, -IncludeDeletedObjects also returns live objects, without isDeleted
            if ($IncludeDeletedObjects -and $sid -eq $script:FlakySid) {
                return [PSCustomObject]@{ DistinguishedName = "CN=Flaky,OU=Users,$script:DomainDN"; ObjectClass = 'user'; isDeleted = $null }
            }
            if ($IncludeDeletedObjects -and $sid -ne $script:FailingSid) { return $null }
            Invoke-SidLookup -Sid $sid
        }

        foreach ($cmdlet in 'Get-ADUser', 'Get-ADGroup', 'Get-ADComputer') {
            Mock -ModuleName OrphanedSid $cmdlet { Invoke-SidLookup -Sid (Get-SidFromFilter -Filter $Filter) }
        }

        Mock -ModuleName OrphanedSid Get-Acl -ParameterFilter { $Path -like 'AD:*' } {
            $dn = [string](@($Path)[0] -replace '^AD:\\?')
            # Measured on a domain controller: for a name with wildcard characters, Get-Acl -Path on
            # the AD: drive returns nothing and raises no error (#119). A backtick escapes the
            # character after it, so for 'Team`*' the drive hands back the object named 'Team*'.
            if ($dn.Contains('`')) {
                $dn = [System.Management.Automation.WildcardPattern]::Unescape($dn)
            } elseif ([System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($dn)) {
                return
            }
            # Measured on Windows PowerShell 5.1: the drive does not read a name in which the
            # directory escaped a character with a backslash (#133). PowerShell 7 reads it; the
            # fake behaves like the edition that fails.
            if ($dn.Contains('\')) { throw 'The object name has bad syntax' }
            if (-not $script:Directory.Contains($dn)) { throw "Cannot find path '$Path' dn=[$dn] count=$($script:Directory.Count) keys=$(@($script:Directory.Keys) -join '|')" }
            Get-DirectoryAcl -DN $dn
        }

        Mock -ModuleName OrphanedSid Set-Acl -ParameterFilter { $Path -like 'AD:*' } {
            $dn = [string](@($Path)[0] -replace '^AD:\\?')
            # The path is a pattern to Set-Acl, so a write through the AD: drive for such a name is
            # a defect; fail the test that makes one
            if ([System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($dn) -or $dn.Contains('`')) {
                throw "Set-Acl -Path was called with a name that contains wildcard characters: $dn"
            }
            if ($dn.Contains('\')) { throw 'The object name has bad syntax' }
            $script:Directory[$dn].Sddl = $AclObject.GetSecurityDescriptorSddlForm('All')
        }

        # The attribute route the module takes for a name with wildcard characters or a backslash
        Mock -ModuleName OrphanedSid Set-ADObject {
            $dn = [string]$Identity
            if (-not $script:Directory.Contains($dn)) { throw "Directory object not found: $dn" }
            $script:Directory[$dn].Sddl = $Replace['nTSecurityDescriptor'].GetSecurityDescriptorSddlForm('All')
        }
    }

    BeforeEach {
        Reset-Directory
        $script:BackupRoot = Join-Path $TestDrive "Backup_$([guid]::NewGuid().ToString('N'))"
        $null = New-Item -Path $script:BackupRoot -ItemType Directory
        # The SID validation cache lives for the PowerShell session; each test starts cold
        InModuleScope OrphanedSid { $script:SIDValidationCache = @{} }
    }

    Context 'Find-OrphanedSid' {
        It 'Reports the orphaned SID on every object that holds it, and nothing else as orphaned' {
            $results = @(Invoke-FindOrphanedSid)

            $orphaned = @($results | Where-Object VerificationStatus -eq 'Orphaned')
            @($orphaned.OrphanedSID | Sort-Object -Unique) | Should -Be @($script:OrphanSid)
            @($orphaned.ObjectDN | Sort-Object) | Should -Be @(
                "CN=Payroll,OU=Finance,$script:DomainDN"
                "OU=Finance,$script:DomainDN"
            )
            $results.OrphanedSID | Should -Not -Contain $script:LiveSid
            $results.OrphanedSID | Should -Not -Contain $script:BuiltinAdmins
        }

        It 'Reports a SID whose lookups fail as Unverified, with the error, not as orphaned' {
            $results = @(Invoke-FindOrphanedSid)

            $failing = @($results | Where-Object OrphanedSID -eq $script:FailingSid)
            $failing.Count | Should -Be 1
            $failing[0].VerificationStatus | Should -Be 'Unverified'
            $failing[0].VerificationError | Should -Match 'Access is denied'
        }

        It 'Writes the same findings, with their verification status, to the -OutputPath CSV' {
            $csvPath = Join-Path $TestDrive 'findings.csv'

            $results = @(Invoke-FindOrphanedSid -OutputPath $csvPath)

            $rows = @(Import-Csv -Path $csvPath)
            $rows.Count | Should -Be $results.Count
            @($rows | Where-Object VerificationStatus -eq 'Orphaned').Count | Should -Be 2
            ($rows | Where-Object OrphanedSID -eq $script:FailingSid).VerificationStatus | Should -Be 'Unverified'
        }

        It 'Returns its findings when WhatIf is in effect for the session' {
            # A module function reads preferences from the global scope, not from its caller's
            $savedWhatIf = $global:WhatIfPreference
            $global:WhatIfPreference = $true
            try {
                $results = @(Invoke-FindOrphanedSid)
            } finally {
                $global:WhatIfPreference = $savedWhatIf
            }

            @($results | Where-Object VerificationStatus -eq 'Orphaned').Count | Should -Be 2
            ($results | Where-Object OrphanedSID -eq $script:FailingSid).VerificationStatus | Should -Be 'Unverified'
        }

        It 'Carries the run correlation ID on every result row and every log line (#42)' {
            $log = Join-Path $TestDrive 'cid.log'

            $results = @(Find-OrphanedSid -SearchBase "OU=Finance,$script:DomainDN" -LogPath $log -SuppressConsoleOutput -CorrelationId 'RUN-42')

            $results.Count | Should -BeGreaterThan 0
            @($results | Where-Object CorrelationId -ne 'RUN-42').Count | Should -Be 0
            $ids = @(Get-LogCorrelationId -Path $log)
            $ids.Count | Should -BeGreaterThan 20
            @($ids | Where-Object { $_ -ne 'RUN-42' } | Select-Object -Unique) | Should -Be @()
        }

        It "Filters the log at the -ConfigPath file's LogLevel unless the command line sets one (#43)" {
            $config = Join-Path $TestDrive 'warning-level.json'
            @{ LogLevel = 'Warning' } | ConvertTo-Json | Set-Content -Path $config
            $fromFile = Join-Path $TestDrive 'level-file.log'
            $fromCommand = Join-Path $TestDrive 'level-command.log'
            $search = "OU=Finance,$script:DomainDN"

            $null = Find-OrphanedSid -SearchBase $search -ConfigPath $config -LogPath $fromFile -SuppressConsoleOutput
            $null = Find-OrphanedSid -SearchBase $search -ConfigPath $config -LogPath $fromCommand -SuppressConsoleOutput -LogLevel Information

            # Written once the configuration is loaded, at Information
            Select-String -Path $fromFile -Pattern 'Find-OrphanedSid starting' -SimpleMatch | Should -BeNullOrEmpty
            Select-String -Path $fromFile -Pattern 'Total objects processed' -SimpleMatch | Should -BeNullOrEmpty
            Select-String -Path $fromFile -Pattern '] [Warning] [' -SimpleMatch | Should -Not -BeNullOrEmpty
            Select-String -Path $fromCommand -Pattern 'Find-OrphanedSid starting' -SimpleMatch | Should -Not -BeNullOrEmpty
            Select-String -Path $fromCommand -Pattern 'Total objects processed' -SimpleMatch | Should -Not -BeNullOrEmpty
        }

        It 'Keeps the earlier run in a reused -LogPath, and rotates it once it outgrows the limit (#44)' {
            $log = Join-Path $TestDrive 'reused.log'
            $search = "OU=Finance,$script:DomainDN"

            $null = Find-OrphanedSid -SearchBase $search -LogPath $log -SuppressConsoleOutput -CorrelationId 'RUN-44A'
            $null = Find-OrphanedSid -SearchBase $search -LogPath $log -SuppressConsoleOutput -CorrelationId 'RUN-44B'

            @(Get-LogCorrelationId -Path $log | Select-Object -Unique) | Should -Be @('RUN-44A', 'RUN-44B')

            # Grow the file past a 1 MB limit; the next run renames it aside before writing
            Add-Content -Path $log -Value ('x' * 1.5MB)
            $config = Join-Path $TestDrive 'rotate-1mb.json'
            @{ MaxLogFileSizeMB = 1 } | ConvertTo-Json | Set-Content -Path $config
            $null = Find-OrphanedSid -SearchBase $search -ConfigPath $config -LogPath $log -SuppressConsoleOutput -CorrelationId 'RUN-44C'

            $rotated = @(Get-ChildItem -Path $TestDrive -Filter 'reused_????????_??????.log')
            $rotated.Count | Should -Be 1
            @(Get-LogCorrelationId -Path $rotated[0].FullName | Select-Object -Unique) | Should -Be @('RUN-44A', 'RUN-44B')
            @(Get-LogCorrelationId -Path $log | Select-Object -Unique) | Should -Be @('RUN-44C')
            Select-String -Path $log -Pattern "Rotated log file to: $([regex]::Escape($rotated[0].FullName))" | Should -Not -BeNullOrEmpty
        }

        It 'Returns typed results with enum names, in the pipeline and the CSV (#41)' {
            $csvPath = Join-Path $TestDrive 'typed.csv'

            $results = @(Invoke-FindOrphanedSid -OutputPath $csvPath)

            $results[0].GetType().Name | Should -Be 'OrphanedSIDResult'
            "$($results[0].ActiveDirectoryRights)" | Should -Be 'ReadProperty, WriteProperty'
            "$($results[0].AccessControlType)" | Should -Be 'Allow'
            $results[0].Timestamp.Kind | Should -Not -Be ([DateTimeKind]::Utc)
            $row = @(Import-Csv -Path $csvPath)[0]
            $row.ActiveDirectoryRights | Should -Be 'ReadProperty, WriteProperty'
            $row.AccessControlType | Should -Be 'Allow'
        }

        It 'Changes no ACL' {
            $null = Invoke-FindOrphanedSid

            Should -Invoke -ModuleName OrphanedSid Set-Acl -Times 0 -Exactly
            foreach ($dn in $script:Directory.Keys) {
                $script:Directory[$dn].Sddl | Should -Be $script:OriginalSddl[$dn]
            }
        }
    }

    Context 'Log file chosen by a configuration file (#90)' {
        BeforeEach {
            $script:priorLocation = Get-Location
            $script:runDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -Path $script:runDir -ItemType Directory | Out-Null
            Set-Location $script:runDir
            $script:configuredLog = Join-Path $script:runDir 'configured.log'
            $script:cfg = Join-Path $script:runDir 'cfg.json'
            @{ LogFilePath = $script:configuredLog } | ConvertTo-Json | Set-Content $script:cfg
        }

        AfterEach {
            Set-Location $script:priorLocation
        }

        It 'Writes the whole run, header first, to the LogFilePath when -LogPath is not given' {
            $null = Find-OrphanedSid -SearchBase "OU=Finance,$script:DomainDN" -ConfigPath $script:cfg -SuppressConsoleOutput -CorrelationId 'cfg-log-1'

            $lines = @(Get-Content $script:configuredLog)
            ($lines | Select-String -Pattern 'Module Version:' -SimpleMatch).Count | Should -Be 1
            ($lines | Select-String -Pattern 'Find-OrphanedSid starting' -SimpleMatch).Count | Should -Be 1
            ($lines | Select-String -Pattern 'Discovery completed' -SimpleMatch).Count | Should -Be 1
            # Before #90 the header and the first lines went to the default file
            Test-Path (Join-Path $script:runDir 'Logs') | Should -BeFalse
        }

        It 'Keeps -LogPath over the configured LogFilePath, and writes the whole run there' {
            $mine = Join-Path $script:runDir 'mine.log'

            $null = Find-OrphanedSid -SearchBase "OU=Finance,$script:DomainDN" -ConfigPath $script:cfg -LogPath $mine -SuppressConsoleOutput

            Test-Path $script:configuredLog | Should -BeFalse
            @(Select-String -Path $mine -Pattern 'Module Version:' -SimpleMatch).Count | Should -Be 1
            @(Select-String -Path $mine -Pattern 'Discovery completed' -SimpleMatch).Count | Should -Be 1
        }
    }

    Context '-MaxRetries reaches the directory lookups (#89)' {
        BeforeEach {
            # The retry back-off is not what is under test
            Mock -ModuleName OrphanedSid Start-Sleep { }
            $dn = "CN=Transient,OU=Finance,$script:DomainDN"
            $script:Directory[$dn] = New-DirectoryObject -DN $dn -ObjectClass 'group' -Trustee $script:TransientSid
        }

        It 'Settles a SID whose lookup recovers within -MaxRetries, and reports it orphaned' {
            # Three timeouts, then not-found: the fourth attempt answers. Before #89 every lookup
            # made three attempts whatever -MaxRetries said, so this SID came back Unverified.
            $script:TransientFailures = 3

            $transient = @(Invoke-FindOrphanedSid -MaxRetries 3 | Where-Object OrphanedSID -eq $script:TransientSid)

            $transient.Count | Should -Be 1
            $transient[0].VerificationStatus | Should -Be 'Orphaned'
            $script:TransientFailures | Should -Be 0
        }

        It 'Leaves the same SID unverified when -MaxRetries is too low for it to recover' {
            # Two timeouts outlast one retry. Before #89 the lookup's third attempt answered.
            $script:TransientFailures = 2

            $transient = @(Invoke-FindOrphanedSid -MaxRetries 1 | Where-Object OrphanedSID -eq $script:TransientSid)

            $transient.Count | Should -Be 1
            $transient[0].VerificationStatus | Should -Be 'Unverified'
            $transient[0].VerificationError | Should -Match 'timeout limit was exceeded'
        }
    }

    Context 'Remove-OrphanedSid' {
        It 'Removes the orphaned ACE from every object that held it' {
            $null = Invoke-RemoveOrphanedSid

            Get-TrusteeSid -DN "OU=Finance,$script:DomainDN" | Should -Not -Contain $script:OrphanSid
            Get-TrusteeSid -DN "CN=Payroll,OU=Finance,$script:DomainDN" | Should -Not -Contain $script:OrphanSid
        }

        It 'Keeps the live, built-in and unverified ACEs' {
            $null = Invoke-RemoveOrphanedSid

            $finance = Get-TrusteeSid -DN "OU=Finance,$script:DomainDN"
            $finance | Should -Contain $script:LiveSid
            $finance | Should -Contain $script:BuiltinAdmins
            Get-TrusteeSid -DN "CN=Payroll,OU=Finance,$script:DomainDN" | Should -Contain $script:FailingSid
        }

        It 'Keeps the entry of a live principal whose ordinary lookups time out (#39)' {
            # The retry back-off would only slow the test down
            Mock -ModuleName OrphanedSid Start-Sleep { }
            $dn = "CN=Shared,OU=Finance,$script:DomainDN"
            $script:Directory[$dn] = New-DirectoryObject -DN $dn -ObjectClass 'group' -Trustee $script:FlakySid
            $script:OriginalSddl[$dn] = $script:Directory[$dn].Sddl

            $null = Invoke-RemoveOrphanedSid

            Get-TrusteeSid -DN $dn | Should -Contain $script:FlakySid
            $script:Directory[$dn].Sddl | Should -Be $script:OriginalSddl[$dn]
            @(Get-ChildItem -Path $script:BackupRoot -Filter 'CN_Shared_*' -Recurse).Count | Should -Be 0
        }

        It 'Leaves an orphaned entry that is only inherited, and backs nothing up (#46)' {
            $dn = "CN=Child,OU=Finance,$script:DomainDN"
            # ID marks the entry as inherited from a parent object
            $script:Directory[$dn] = @{ ObjectClass = 'group'; Sddl = "O:BAG:BAD:(A;;GA;;;BA)(A;ID;RPWP;;;$($script:OrphanSid))" }
            $script:OriginalSddl[$dn] = $script:Directory[$dn].Sddl

            $results = @(Invoke-RemoveOrphanedSid -IncludeInherited)

            $script:Directory[$dn].Sddl | Should -Be $script:OriginalSddl[$dn]
            Should -Invoke -ModuleName OrphanedSid Set-Acl -Times 0 -Exactly -ParameterFilter { $Path -like '*CN=Child,*' }
            @(Get-ChildItem -Path $script:BackupRoot -Filter 'CN_Child_*' -Recurse).Count | Should -Be 0
            @($results | Where-Object ObjectDN -eq $dn).Count | Should -Be 0
        }

        It 'Stamps the backup and the log with the module version and the backup with UTC time (#52)' {
            $manifestVersion = (Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot '..\..\OrphanedSid.psd1')).ModuleVersion
            $log = Join-Path $TestDrive 'version.log'

            $results = @(Remove-OrphanedSid -SearchBase "OU=Finance,$script:DomainDN" -BackupPath $script:BackupRoot -Force -LogPath $log -SuppressConsoleOutput)

            $backup = Import-Clixml -Path $results[0].BackupFile
            $backup.ScriptVersion | Should -Be $manifestVersion
            $stamp = [DateTimeOffset]::ParseExact($backup.BackupDate, "yyyy-MM-dd'T'HH:mm:ss.fffK", [System.Globalization.CultureInfo]::InvariantCulture)
            ([DateTime]::UtcNow - $stamp.UtcDateTime).TotalMinutes | Should -BeLessThan 5
            ([DateTime]::UtcNow - $stamp.UtcDateTime).TotalMinutes | Should -BeGreaterThan -1
            Select-String -Path $log -Pattern "Module Version: $manifestVersion" -SimpleMatch | Should -Not -BeNullOrEmpty
        }

        It 'Writes no CSV under -WhatIf, and its log says no file was written (#50)' {
            $log = Join-Path $TestDrive 'whatif-export.log'
            $csv = Join-Path $TestDrive 'whatif-export.csv'

            $null = Remove-OrphanedSid -SearchBase "OU=Finance,$script:DomainDN" -BackupPath $script:BackupRoot -OutputPath $csv -LogPath $log -SuppressConsoleOutput -WhatIf

            Test-Path $csv | Should -BeFalse
            Select-String -Path $log -Pattern 'Results exported to:' -SimpleMatch | Should -BeNullOrEmpty
            Select-String -Path $log -Pattern "WhatIf: results would be exported to $csv; no file was written" -SimpleMatch | Should -Not -BeNullOrEmpty
        }

        It 'Names the backup file in each removal result and in its audit entry (#49)' {
            $log = Join-Path $TestDrive 'audit-remove.log'

            $results = @(Remove-OrphanedSid -SearchBase "OU=Finance,$script:DomainDN" -BackupPath $script:BackupRoot -Force -LogPath $log -SuppressConsoleOutput)

            $results.Count | Should -Be 2
            foreach ($result in $results) {
                $result.BackupFile | Should -Exist
                (Import-Clixml -Path $result.BackupFile).ObjectDN | Should -Be $result.ObjectDN
            }
            # Security entries are JSON lines with the context flattened under a Security_ prefix
            $audit = @(Get-Content -Path $log | Where-Object { $_.StartsWith('{') } | ForEach-Object { $_ | ConvertFrom-Json } |
                    Where-Object { $_.Security_OperationName -eq 'OrphanedSID-Removal' -and $_.Outcome -eq 'Success' })
            $audit.Count | Should -Be 2
            foreach ($entry in $audit) {
                $entry.Security_BackupFile | Should -BeIn $results.BackupFile
                $entry.Security_BackupCreated | Should -BeTrue
                $entry.Security_ActualRemovals | Should -Be 1
                $entry.PSObject.Properties.Name | Should -Not -Contain 'Security_RemovedCount'
            }
        }

        It 'Writes each security entry with its [type] [outcome] message prefix (#55)' {
            $log = Join-Path $TestDrive 'audit-message.log'

            $null = Remove-OrphanedSid -SearchBase "OU=Finance,$script:DomainDN" -BackupPath $script:BackupRoot -Force -LogPath $log -SuppressConsoleOutput

            $entries = @(Get-Content -Path $log | Where-Object { $_.StartsWith('{') } | ForEach-Object { $_ | ConvertFrom-Json } |
                    Where-Object Component -eq 'SecurityAudit')
            $entries.Count | Should -BeGreaterThan 0
            foreach ($entry in $entries) {
                $entry.Message | Should -BeLike "[[]$($entry.SecurityEventType)] [[]$($entry.Outcome)] *"
            }
            @($entries | Where-Object { $_.Message -eq '[ObjectAccess] [Success] Successfully completed Active Directory operation: OrphanedSID-Removal' }).Count |
                Should -Be 2
        }

        It 'Carries the run correlation ID on every log line of a removal (#42)' {
            $log = Join-Path $TestDrive 'cid-remove.log'

            $null = Remove-OrphanedSid -SearchBase "OU=Finance,$script:DomainDN" -BackupPath $script:BackupRoot -Force -LogPath $log -SuppressConsoleOutput -CorrelationId 'RUN-42R'

            @(Get-LogCorrelationId -Path $log | Where-Object { $_ -ne 'RUN-42R' } | Select-Object -Unique) | Should -Be @()
        }

        It 'Leaves an object with no orphaned ACE untouched' {
            $null = Invoke-RemoveOrphanedSid

            $dn = "CN=Clean,OU=Finance,$script:DomainDN"
            $script:Directory[$dn].Sddl | Should -Be $script:OriginalSddl[$dn]
            Should -Invoke -ModuleName OrphanedSid Set-Acl -Times 0 -Exactly -ParameterFilter { $Path -like "*CN=Clean,*" }
        }

        It 'Writes a backup holding the original security descriptor of each object it changed' {
            $null = Invoke-RemoveOrphanedSid

            $backups = @(Get-ChildItem -Path $script:BackupRoot -Filter '*.xml' -Recurse)
            $backups.Count | Should -Be 2
            foreach ($file in $backups) {
                $backup = Import-Clixml -Path $file.FullName
                $script:OriginalSddl.Keys | Should -Contain $backup.ObjectDN
                $original = Get-DirectoryAcl -DN $backup.ObjectDN
                $original.SetSecurityDescriptorSddlForm($script:OriginalSddl[$backup.ObjectDN])
                $backup.SDDL | Should -Be $original.GetSecurityDescriptorSddlForm('All')
            }
        }

        It 'Changes nothing and writes no backup under -WhatIf' {
            $null = Invoke-RemoveOrphanedSid -WhatIf

            Should -Invoke -ModuleName OrphanedSid Set-Acl -Times 0 -Exactly
            foreach ($dn in $script:Directory.Keys) {
                $script:Directory[$dn].Sddl | Should -Be $script:OriginalSddl[$dn]
            }
            @(Get-ChildItem -Path $script:BackupRoot -Filter '*.xml' -Recurse).Count | Should -Be 0
        }
    }

    Context 'Scale' -Tag 'Performance' {
        It 'Looks each SID up once per run, however many ACEs reference it' {
            Reset-Directory -ExtraObjects 40

            $results = @(Invoke-FindOrphanedSid)

            # 42 objects carry the orphaned SID and 42 the live one
            @($results | Where-Object VerificationStatus -eq 'Orphaned').Count | Should -Be 42
            foreach ($sid in $script:OrphanSid, $script:LiveSid) {
                Should -Invoke -ModuleName OrphanedSid Get-ADObject -Times 1 -Exactly -ParameterFilter {
                    -not $IncludeDeletedObjects -and $Filter -eq "objectSid -eq '$sid'"
                }
            }
        }

        It 'Looks a SID up again in the next run when its lookup failed' {
            $null = Invoke-FindOrphanedSid
            $null = Invoke-FindOrphanedSid

            Should -Invoke -ModuleName OrphanedSid Get-ADObject -Times 2 -Exactly -ParameterFilter {
                -not $IncludeDeletedObjects -and $Filter -eq "objectSid -eq '$script:FailingSid'"
            }
            Should -Invoke -ModuleName OrphanedSid Get-ADObject -Times 1 -Exactly -ParameterFilter {
                -not $IncludeDeletedObjects -and $Filter -eq "objectSid -eq '$script:OrphanSid'"
            }
        }
    }

    Context 'Square brackets in an object name and in path parameters (#119)' {
        BeforeEach {
            $script:BracketDN = "CN=Payroll [EU],OU=Finance,$script:DomainDN"
            $script:Directory[$script:BracketDN] =
                New-DirectoryObject -DN $script:BracketDN -ObjectClass 'group' -Trustee $script:LiveSid, $script:OrphanSid
            $script:OriginalSddl[$script:BracketDN] = $script:Directory[$script:BracketDN].Sddl
            $script:BracketFolder = Join-Path $TestDrive "Run [1] $([guid]::NewGuid().ToString('N'))"
            $null = New-Item -Path $script:BracketFolder -ItemType Directory
            $script:Search = "OU=Finance,$script:DomainDN"
        }

        It 'Removes the orphaned entry from an object whose name contains square brackets, and backs it up' {
            $results = @(Invoke-RemoveOrphanedSid)

            Get-TrusteeSid -DN $script:BracketDN | Should -Not -Contain $script:OrphanSid
            Get-TrusteeSid -DN $script:BracketDN | Should -Contain $script:LiveSid
            $result = @($results | Where-Object ObjectDN -eq $script:BracketDN)
            $result.Count | Should -Be 1
            $result[0].Success | Should -BeTrue
            $result[0].ActualRemovals | Should -Be 1
            Test-Path -LiteralPath $result[0].BackupFile -PathType Leaf | Should -BeTrue
            [System.IO.Path]::GetFileName($result[0].BackupFile) | Should -Not -Match '[\[\]]'
        }

        It 'Reports the entries of an object whose name holds a backtick, not those of the sibling the AD: drive hands back for it' {
            $tickDN = 'CN=Team`*,OU=Finance,' + $script:DomainDN
            $siblingDN = 'CN=Team*,OU=Finance,' + $script:DomainDN
            $script:Directory[$tickDN] =
                New-DirectoryObject -DN $tickDN -ObjectClass 'group' -Trustee $script:LiveSid, $script:OrphanSid
            $script:Directory[$siblingDN] = New-DirectoryObject -DN $siblingDN -ObjectClass 'group' -Trustee $script:LiveSid

            $results = @(Invoke-FindOrphanedSid)

            $orphaned = @($results | Where-Object VerificationStatus -eq 'Orphaned')
            @($orphaned | Where-Object ObjectDN -eq $tickDN).Count | Should -Be 1
            @($orphaned | Where-Object ObjectDN -eq $siblingDN).Count | Should -Be 0
        }

        It 'Restores an object whose name contains square brackets from its backup' {
            $null = Invoke-RemoveOrphanedSid
            Get-TrusteeSid -DN $script:BracketDN | Should -Not -Contain $script:OrphanSid
            $backupFolder = (Get-ChildItem -LiteralPath $script:BackupRoot -Directory | Select-Object -First 1).FullName

            $parameters = @{
                TargetObjectDN        = $script:BracketDN
                BackupPath            = $backupFolder
                LogPath               = Join-Path $TestDrive 'restore-brackets.log'
                SuppressConsoleOutput = $true
                Force                 = $true
            }
            $result = Restore-OrphanedSidBackup @parameters

            $result.Success | Should -BeTrue
            Get-TrusteeSid -DN $script:BracketDN | Should -Contain $script:OrphanSid
            Get-TrusteeSid -DN $script:BracketDN | Should -Contain $script:LiveSid
        }

        It 'Writes the whole log of a removal to a -LogPath that contains square brackets' {
            $log = Join-Path $script:BracketFolder 'run[1].log'

            $null = Remove-OrphanedSid -SearchBase $script:Search -BackupPath $script:BackupRoot -LogPath $log -SuppressConsoleOutput -Force

            $lines = @(Get-Content -LiteralPath $log)
            @($lines -match 'Remove-OrphanedSid starting').Count | Should -Be 1
            @($lines -match 'Removal completed').Count | Should -Be 1
            @($lines -match 'SECURITY EVENT').Count | Should -BeGreaterThan 0
        }

        It 'Writes the backups under a -BackupPath that contains square brackets' {
            $backupRoot = Join-Path $script:BracketFolder 'Backup [prod]'
            $null = New-Item -Path $backupRoot -ItemType Directory
            $log = Join-Path $TestDrive 'remove.log'

            $results = @(Remove-OrphanedSid -SearchBase $script:Search -BackupPath $backupRoot -LogPath $log -SuppressConsoleOutput -Force)

            $results.Count | Should -Be 3
            @($results | Where-Object { -not $_.Success }).Count | Should -Be 0
            @(Get-ChildItem -LiteralPath $backupRoot -Recurse -File -Filter '*.xml').Count | Should -Be 3
            Get-TrusteeSid -DN $script:Search | Should -Not -Contain $script:OrphanSid
        }

        It 'Writes the CSV to an -OutputPath that contains square brackets' {
            $csv = Join-Path $script:BracketFolder 'findings[1].csv'
            $log = Join-Path $TestDrive 'find.log'

            $results = @(Find-OrphanedSid -SearchBase $script:Search -OutputPath $csv -LogPath $log -SuppressConsoleOutput)

            $results.Count | Should -BeGreaterThan 0
            Test-Path -LiteralPath $csv -PathType Leaf | Should -BeTrue
            @(Import-Csv -LiteralPath $csv).Count | Should -Be $results.Count
        }

        It 'Loads a -ConfigPath that contains square brackets' {
            $config = Join-Path $script:BracketFolder 'settings [prod].json'
            @{ ProtectedSIDs = @($script:OrphanSid) } | ConvertTo-Json | Set-Content -LiteralPath $config
            $log = Join-Path $TestDrive 'find.log'

            $results = @(Find-OrphanedSid -SearchBase $script:Search -ConfigPath $config -LogPath $log -SuppressConsoleOutput)

            # The file protects the SID that is otherwise reported, so its absence shows the file was read
            $results.OrphanedSID | Should -Not -Contain $script:OrphanSid
            $results.OrphanedSID | Should -Contain $script:FailingSid
        }
    }

    Context 'A character in an object name that another interpreter gives a meaning (#128)' {
        BeforeEach {
            # The loop variables must not be called $name or $dn: the cases below receive $Name from
            # -ForEach, and a variable of that name set here would replace it in every case.
            $containerNames = @(
                'R&D', 'Ops | Support', 'Tick`Name', 'Smith--Jones', '100%Cotton', 'Misc...', 'Sales\; Marketing'
            )
            foreach ($containerName in $containerNames) {
                $containerDN = "OU=$containerName,OU=Finance,$script:DomainDN"
                $script:Directory[$containerDN] =
                    New-DirectoryObject -DN $containerDN -ObjectClass 'organizationalUnit' -Trustee $script:LiveSid, $script:OrphanSid
                $script:OriginalSddl[$containerDN] = $script:Directory[$containerDN].Sddl
            }
            $script:BelowDN = "CN=Below,OU=R&D,OU=Finance,$script:DomainDN"
            $script:Directory[$script:BelowDN] =
                New-DirectoryObject -DN $script:BelowDN -ObjectClass 'group' -Trustee $script:LiveSid, $script:OrphanSid
            $script:OriginalSddl[$script:BelowDN] = $script:Directory[$script:BelowDN].Sddl
            $script:OddDNs = @(
                foreach ($containerName in $containerNames) {
                    "OU=$containerName,OU=Finance,$script:DomainDN"
                }
                $script:BelowDN
            )
        }

        # One removal run for all eight objects: a run takes several seconds, whatever it finds.
        It 'Removes the orphaned entry from each such object, and from an object below one' {
            $targets = @($script:OddDNs)
            $targets.Count | Should -Be 8

            $results = @(Invoke-RemoveOrphanedSid)

            # Each line names an object that was not cleaned, with the error the removal gave for it
            $notCleaned = @(foreach ($target in $targets) {
                    $result = @($results | Where-Object ObjectDN -eq $target)
                    $trustees = @(Get-TrusteeSid -DN $target)
                    $cleaned = $result.Count -eq 1 -and $result[0].Success -and $result[0].ActualRemovals -eq 1 -and
                        $trustees -notcontains $script:OrphanSid -and $trustees -contains $script:LiveSid
                    if (-not $cleaned) {
                        "$target [$(@($result.ErrorMessage) -join '; ')]"
                    }
                })
            $notCleaned | Should -BeNullOrEmpty
        }

        It 'Takes the container named <Name> as the search base' -ForEach @(
            @{ Name = 'R&D'; Expected = 2 }
            @{ Name = 'Ops | Support'; Expected = 1 }
            @{ Name = 'Tick`Name'; Expected = 1 }
            @{ Name = 'Smith--Jones'; Expected = 1 }
            @{ Name = '100%Cotton'; Expected = 1 }
            @{ Name = 'Misc...'; Expected = 1 }
            @{ Name = 'Sales\; Marketing'; Expected = 1 }
        ) {
            $dn = "OU=$Name,OU=Finance,$script:DomainDN"
            $log = Join-Path $TestDrive 'find-base.log'

            $results = @(Find-OrphanedSid -SearchBase $dn -LogPath $log -SuppressConsoleOutput)

            $orphaned = @($results | Where-Object VerificationStatus -eq 'Orphaned')
            $orphaned.Count | Should -Be $Expected
            @($orphaned | Where-Object ObjectDN -eq $dn).Count | Should -Be 1
        }

        It 'Restores an object below a container named R&D from its backup' {
            $null = Invoke-RemoveOrphanedSid
            Get-TrusteeSid -DN $script:BelowDN | Should -Not -Contain $script:OrphanSid
            $backupFolder = (Get-ChildItem -LiteralPath $script:BackupRoot -Directory | Select-Object -First 1).FullName

            $parameters = @{
                TargetObjectDN        = $script:BelowDN
                BackupPath            = $backupFolder
                LogPath               = Join-Path $TestDrive 'restore-below.log'
                SuppressConsoleOutput = $true
                Force                 = $true
            }
            $result = Restore-OrphanedSidBackup @parameters

            $result.Success | Should -BeTrue
            Get-TrusteeSid -DN $script:BelowDN | Should -Contain $script:OrphanSid
        }
    }

    Context 'An object that is named by an attribute other than CN, OU or DC (#134)' {
        BeforeEach {
            $script:LocalityDN = "L=Springfield,OU=Finance,$script:DomainDN"
            $script:OrganizationDN = "O=Acme,$script:LocalityDN"
            $script:DepotDN = "OU=Depot,$script:OrganizationDN"
            $classes = @{
                $script:LocalityDN = 'locality'
                $script:OrganizationDN = 'organization'
                $script:DepotDN = 'organizationalUnit'
            }
            foreach ($entry in $classes.GetEnumerator()) {
                $script:Directory[$entry.Key] =
                    New-DirectoryObject -DN $entry.Key -ObjectClass $entry.Value -Trustee $script:LiveSid, $script:OrphanSid
                $script:OriginalSddl[$entry.Key] = $script:Directory[$entry.Key].Sddl
            }
        }

        It 'Removes the orphaned entry from a locality, an organization below it and a unit below that' {
            $targets = @($script:LocalityDN, $script:OrganizationDN, $script:DepotDN)

            $results = @(Invoke-RemoveOrphanedSid)

            # Each line names an object that was not cleaned, with the error the removal gave for it
            $notCleaned = @(foreach ($target in $targets) {
                    $result = @($results | Where-Object ObjectDN -eq $target)
                    $trustees = @(Get-TrusteeSid -DN $target)
                    $cleaned = $result.Count -eq 1 -and $result[0].Success -and $result[0].ActualRemovals -eq 1 -and
                        $trustees -notcontains $script:OrphanSid -and $trustees -contains $script:LiveSid
                    if (-not $cleaned) {
                        "$target [$(@($result.ErrorMessage) -join '; ')]"
                    }
                })
            $notCleaned | Should -BeNullOrEmpty
        }

        It 'Takes a locality as the search base' {
            $log = Join-Path $TestDrive 'find-locality.log'

            $results = @(Find-OrphanedSid -SearchBase $script:LocalityDN -LogPath $log -SuppressConsoleOutput)

            $orphaned = @($results | Where-Object VerificationStatus -eq 'Orphaned')
            $orphaned.Count | Should -Be 3
            @($orphaned | Where-Object ObjectDN -eq $script:LocalityDN).Count | Should -Be 1
        }

        It 'Restores <Case> from its backup' -ForEach @(
            @{ Case = 'a locality'; Target = 'LocalityDN' }
            @{ Case = 'an organization below a locality'; Target = 'OrganizationDN' }
        ) {
            $targetDN = Get-Variable -Name $Target -Scope Script -ValueOnly
            $null = Invoke-RemoveOrphanedSid
            Get-TrusteeSid -DN $targetDN | Should -Not -Contain $script:OrphanSid
            $backupFolder = (Get-ChildItem -LiteralPath $script:BackupRoot -Directory | Select-Object -First 1).FullName

            $parameters = @{
                TargetObjectDN        = $targetDN
                BackupPath            = $backupFolder
                LogPath               = Join-Path $TestDrive 'restore-locality.log'
                SuppressConsoleOutput = $true
                Force                 = $true
            }
            $result = Restore-OrphanedSidBackup @parameters

            $result.Success | Should -BeTrue
            Get-TrusteeSid -DN $targetDN | Should -Contain $script:OrphanSid
        }
    }

    Context 'A character that the directory escapes in an object name (#133)' {
        BeforeEach {
            $script:EscapedDN = 'CN=Doe\, Jane,OU=Finance,' + $script:DomainDN
            $script:Directory[$script:EscapedDN] =
                New-DirectoryObject -DN $script:EscapedDN -ObjectClass 'group' -Trustee $script:LiveSid, $script:OrphanSid
            $script:OriginalSddl[$script:EscapedDN] = $script:Directory[$script:EscapedDN].Sddl
        }

        It 'Reports the orphaned entry of an object whose name holds an escaped comma' {
            $results = @(Invoke-FindOrphanedSid)

            $orphaned = @($results | Where-Object VerificationStatus -eq 'Orphaned')
            @($orphaned | Where-Object ObjectDN -eq $script:EscapedDN).Count | Should -Be 1
        }

        It 'Removes the orphaned entry from an object whose name holds an escaped comma, and backs it up' {
            $results = @(Invoke-RemoveOrphanedSid)

            Get-TrusteeSid -DN $script:EscapedDN | Should -Not -Contain $script:OrphanSid
            Get-TrusteeSid -DN $script:EscapedDN | Should -Contain $script:LiveSid
            $result = @($results | Where-Object ObjectDN -eq $script:EscapedDN)
            $result.Count | Should -Be 1
            $result[0].Success | Should -BeTrue
            $result[0].ActualRemovals | Should -Be 1
            Test-Path -LiteralPath $result[0].BackupFile -PathType Leaf | Should -BeTrue
        }

        It 'Restores an object whose name holds an escaped comma from its backup' {
            $null = Invoke-RemoveOrphanedSid
            Get-TrusteeSid -DN $script:EscapedDN | Should -Not -Contain $script:OrphanSid
            $backupFolder = (Get-ChildItem -LiteralPath $script:BackupRoot -Directory | Select-Object -First 1).FullName

            $parameters = @{
                TargetObjectDN        = $script:EscapedDN
                BackupPath            = $backupFolder
                LogPath               = Join-Path $TestDrive 'restore-escaped.log'
                SuppressConsoleOutput = $true
                Force                 = $true
            }
            $result = Restore-OrphanedSidBackup @parameters

            $result.Success | Should -BeTrue
            Get-TrusteeSid -DN $script:EscapedDN | Should -Contain $script:OrphanSid
            Get-TrusteeSid -DN $script:EscapedDN | Should -Contain $script:LiveSid
        }
    }

    Context 'Restore-OrphanedSidBackup' {
        It 'Puts back the security descriptor a removal backed up' {
            $null = Invoke-RemoveOrphanedSid
            $dn = "OU=Finance,$script:DomainDN"
            Get-TrusteeSid -DN $dn | Should -Not -Contain $script:OrphanSid
            $backupFolder = (Get-ChildItem -Path $script:BackupRoot -Directory | Select-Object -First 1).FullName

            $parameters = @{
                TargetObjectDN        = $dn
                BackupPath            = $backupFolder
                LogPath               = Join-Path $TestDrive 'restore.log'
                SuppressConsoleOutput = $true
                Force                 = $true
            }
            $result = Restore-OrphanedSidBackup @parameters

            $result.Success | Should -BeTrue
            Get-TrusteeSid -DN $dn | Should -Contain $script:OrphanSid
            Get-TrusteeSid -DN $dn | Should -Contain $script:LiveSid
        }

        It 'Puts back every orphaned SID removed from one object (#40)' {
            $dn = "CN=Two,OU=Finance,$script:DomainDN"
            $script:Directory[$dn] = New-DirectoryObject -DN $dn -ObjectClass 'group' -Trustee $script:OrphanSid, $script:SecondOrphanSid
            $script:OriginalSddl[$dn] = $script:Directory[$dn].Sddl

            $null = Invoke-RemoveOrphanedSid

            Get-TrusteeSid -DN $dn | Should -Not -Contain $script:OrphanSid
            Get-TrusteeSid -DN $dn | Should -Not -Contain $script:SecondOrphanSid
            $backups = @(Get-ChildItem -Path $script:BackupRoot -Filter 'CN_Two_*' -Recurse)
            $backups.Count | Should -Be 1

            $parameters = @{
                TargetObjectDN        = $dn
                BackupPath            = $backups[0].DirectoryName
                LogPath               = Join-Path $TestDrive 'restore.log'
                SuppressConsoleOutput = $true
                Force                 = $true
            }
            (Restore-OrphanedSidBackup @parameters).Success | Should -BeTrue

            Get-TrusteeSid -DN $dn | Should -Contain $script:OrphanSid
            Get-TrusteeSid -DN $dn | Should -Contain $script:SecondOrphanSid
        }
        It 'Reports a failed write once, with one prefix (#51)' {
            $null = Invoke-RemoveOrphanedSid
            $dn = "OU=Finance,$script:DomainDN"
            $backupFolder = (Get-ChildItem -Path $script:BackupRoot -Directory | Select-Object -First 1).FullName
            Mock -ModuleName OrphanedSid Set-Acl -ParameterFilter { $Path -like 'AD:*' } { throw 'Access is denied' }

            $parameters = @{
                TargetObjectDN        = $dn
                BackupPath            = $backupFolder
                LogPath               = Join-Path $TestDrive 'restore-denied.log'
                OutputPath            = Join-Path $TestDrive 'restore-denied.csv'
                SuppressConsoleOutput = $true
                Force                 = $true
            }
            $result = Restore-OrphanedSidBackup @parameters -ErrorAction SilentlyContinue -WarningAction SilentlyContinue

            # The OU and its child are restored together, one per-object result each
            $result.Success | Should -BeFalse
            @($result.IndividualResults).Count | Should -Be 2
            foreach ($objectResult in $result.IndividualResults) {
                $objectResult.ErrorMessage | Should -Be 'ACL application failed: Access is denied'
            }
            # And the summary says why (#70)
            $result.ErrorMessage | Should -Be '2 of 2 objects failed to restore: ACL application failed: Access is denied'
            (Import-Csv -Path $parameters.OutputPath).ErrorMessage | Should -Be '2 of 2 objects failed to restore: ACL application failed: Access is denied'
        }

        It 'Refuses a backup whose security descriptor no longer matches its hash' {
            $null = Invoke-RemoveOrphanedSid
            $dn = "OU=Finance,$script:DomainDN"
            $afterRemoval = $script:Directory[$dn].Sddl
            $backupFolder = (Get-ChildItem -Path $script:BackupRoot -Directory | Select-Object -First 1).FullName
            $file = Get-ChildItem -Path $backupFolder -Filter '*.xml' |
                Where-Object { (Import-Clixml -Path $_.FullName).ObjectDN -eq $dn }
            $backup = Import-Clixml -Path $file.FullName
            $backup.SDDL = $backup.SDDL + '(A;;GA;;;WD)'
            $backup | Export-Clixml -Path $file.FullName

            $parameters = @{
                TargetObjectDN        = $dn
                BackupPath            = $backupFolder
                LogPath               = Join-Path $TestDrive 'restore.log'
                SuppressConsoleOutput = $true
                Force                 = $true
            }
            $result = Restore-OrphanedSidBackup @parameters -ErrorAction SilentlyContinue

            $result.Success | Should -Not -BeTrue
            $script:Directory[$dn].Sddl | Should -Be $afterRemoval
            Get-TrusteeSid -DN $dn | Should -Not -Contain 'S-1-1-0'
        }
    }
}

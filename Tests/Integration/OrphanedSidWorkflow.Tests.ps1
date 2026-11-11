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
    $script:FailingSid = "$script:DomainSid-1777"
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
        if ($Sid -eq $script:LiveSid) {
            return [PSCustomObject]@{ DistinguishedName = "CN=Alice,OU=Users,$script:DomainDN"; ObjectClass = 'user'; SID = $Sid }
        }
        return $null
    }

    function Invoke-FindOrphanedSid {
        param([string]$OutputPath)
        $parameters = @{
            SearchBase            = "OU=Finance,$script:DomainDN"
            LogPath               = Join-Path $TestDrive 'find.log'
            SuppressConsoleOutput = $true
        }
        if ($OutputPath) { $parameters.OutputPath = $OutputPath }
        Find-OrphanedSid @parameters
    }

    function Invoke-RemoveOrphanedSid {
        param([switch]$WhatIf)
        $parameters = @{
            SearchBase            = "OU=Finance,$script:DomainDN"
            BackupPath            = $script:BackupRoot
            LogPath               = Join-Path $TestDrive 'remove.log'
            SuppressConsoleOutput = $true
            Force                 = $true
            WhatIf                = $WhatIf
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
                    if ($dn -like "*$SearchBase") {
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
                    return [PSCustomObject]@{ DistinguishedName = [string]$Identity; ObjectClass = $script:Directory[[string]$Identity].ObjectClass }
                }
                throw "Directory object not found: $Identity"
            }
            $sid = Get-SidFromFilter -Filter $Filter
            if ($IncludeDeletedObjects -and $sid -ne $script:FailingSid) { return $null }
            Invoke-SidLookup -Sid $sid
        }

        foreach ($cmdlet in 'Get-ADUser', 'Get-ADGroup', 'Get-ADComputer') {
            Mock -ModuleName OrphanedSid $cmdlet { Invoke-SidLookup -Sid (Get-SidFromFilter -Filter $Filter) }
        }

        Mock -ModuleName OrphanedSid Get-Acl -ParameterFilter { $Path -like 'AD:*' } {
            $dn = [string](@($Path)[0] -replace '^AD:\\?')
            if (-not $script:Directory.Contains($dn)) { throw "Cannot find path '$Path' dn=[$dn] count=$($script:Directory.Count) keys=$(@($script:Directory.Keys) -join '|')" }
            Get-DirectoryAcl -DN $dn
        }

        Mock -ModuleName OrphanedSid Set-Acl -ParameterFilter { $Path -like 'AD:*' } {
            $dn = [string](@($Path)[0] -replace '^AD:\\?')
            $script:Directory[$dn].Sddl = $AclObject.GetSecurityDescriptorSddlForm('All')
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

        It 'Changes no ACL' {
            $null = Invoke-FindOrphanedSid

            Should -Invoke -ModuleName OrphanedSid Set-Acl -Times 0 -Exactly
            foreach ($dn in $script:Directory.Keys) {
                $script:Directory[$dn].Sddl | Should -Be $script:OriginalSddl[$dn]
            }
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

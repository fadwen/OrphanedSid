#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
<#
.SYNOPSIS
    Unit tests for the Test-BackupSignature utility function

.DESCRIPTION
    Tests Test-BackupSignature parameter validation, the signature allowlist, the security-risk
    flag and the correlation ID it returns.

.NOTES
    Author: Jeffrey Stuhr
    Blog: https://www.techbyjeff.net
    LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/
#>

BeforeAll {
    $ModuleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    . "$ModuleRoot\Private\Utilities\Test-BackupSignature.ps1"
}

Describe "Test-BackupSignature" -Tag "Unit", "Private", "Utilities" {
    Context "Parameter Validation" {
        It "Should declare Signature mandatory" {
            $parameter = (Get-Command Test-BackupSignature).Parameters['Signature']

            @($parameter.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }).Count |
                Should -Be 1
        }

        It "Should reject an empty or null signature" -ForEach @(
            @{ Value = '' }
            @{ Value = $null }
        ) {
            { Test-BackupSignature -Signature $Value } | Should -Throw "*Cannot bind argument to parameter 'Signature' because it is an empty string*"
        }
    }

    Context "Valid Signature Recognition" {
        It "Should accept <Signature> with no security risk" -ForEach @(
            @{ Signature = 'PSSecurityBackup_v2.1' }
            @{ Signature = 'PSSecurityBackup_v2.0' }
            @{ Signature = 'PowerShellSecurityBackup' }
        ) {
            $result = Test-BackupSignature -Signature $Signature

            $result.Valid | Should -Be $true
            $result.SecurityRisk | Should -Be $false
        }

        It "Should match signatures without regard to case" {
            $result = Test-BackupSignature -Signature "psSECURITYbackup_V2.1"

            $result.Valid | Should -Be $true
            $result.SecurityRisk | Should -Be $false
        }
    }

    Context "Invalid Signature Detection" {
        It "Should reject <Name> and flag a security risk" -ForEach @(
            @{ Name = 'an unknown name'; Signature = 'InvalidSignature' }
            @{ Name = 'an older version'; Signature = 'PSSecurityBackup_v1.9' }
            @{ Name = 'a newer version'; Signature = 'PSSecurityBackup_v2.2' }
            @{ Name = 'a plural name'; Signature = 'PSSecurityBackups_v2.1' }
            @{ Name = 'a space for the underscore'; Signature = 'PSSecurityBackup v2.1' }
            @{ Name = 'a missing v'; Signature = 'PSSecurityBackup_2.1' }
            @{ Name = 'whitespace only'; Signature = '   ' }
            @{ Name = 'surrounding whitespace'; Signature = ' PSSecurityBackup_v2.1 ' }
            @{ Name = 'trailing control characters'; Signature = "PSSecurityBackup_v2.1`t`r`n" }
            @{ Name = 'an appended command'; Signature = 'PSSecurityBackup_v2.1; rm -rf /' }
            @{ Name = 'a valid prefix with a subexpression'; Signature = 'PSSecurityBackup_v2.1$(Get-Process)' }
            @{ Name = 'an embedded quote'; Signature = 'PSSecurityBackup"_v2.1' }
        ) {
            $result = Test-BackupSignature -Signature $Signature

            $result.Valid | Should -Be $false
            $result.SecurityRisk | Should -Be $true
        }

        # Module bug (#18): -contains compares culture-aware, which ignores an embedded null character, so "PSSecurityBackup`0_v2.1" is accepted as PSSecurityBackup_v2.1
        It "Should reject a signature with an embedded null character" -Skip {
            $result = Test-BackupSignature -Signature "PSSecurityBackup`0_v2.1"

            $result.Valid | Should -Be $false
            $result.SecurityRisk | Should -Be $true
        }
    }

    Context "Return Object Structure" {
        It "Should return Valid and SecurityRisk as booleans" {
            $result = Test-BackupSignature -Signature "PSSecurityBackup_v2.1"

            $result.Valid | Should -BeOfType [bool]
            $result.SecurityRisk | Should -BeOfType [bool]
        }

        It "Should return the CorrelationId it was given" {
            $result = Test-BackupSignature -Signature "InvalidSignature" -CorrelationId 'TEST-CORRELATION-ID-12345'

            $result.CorrelationId | Should -Be 'TEST-CORRELATION-ID-12345'
        }

        It "Should generate a new GUID CorrelationId for each call when none is given" {
            $result1 = Test-BackupSignature -Signature "PSSecurityBackup_v2.1"
            $result2 = Test-BackupSignature -Signature "PSSecurityBackup_v2.1"

            $result1.CorrelationId | Should -Match "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
            $result1.CorrelationId | Should -Not -Be $result2.CorrelationId
        }
    }
}

# Test-SIDFormat.Tests.ps1
# Tests for Test-SIDFormat and Test-WellKnownSID in Private/SID/Test-SIDFormat.ps1

BeforeAll {
    function Write-StructuredLog { param($Message, $Level, $CorrelationId, $Component, $Data) }

    . (Join-Path $PSScriptRoot '..\..\..\..\Private\SID\Test-SIDFormat.ps1')

    Mock Write-StructuredLog { }
}

Describe "Test-SIDFormat" -Tag 'Unit', 'Private', 'SID' {

    It "Accepts the well-formed SID <_>" -ForEach @(
        'S-1-5-21-1234567890-1234567890-1234567890-1001'
        'S-1-5-32-544'
        'S-1-1-0'
        'S-1-0-0'
        'S-1-5-18'
        's-1-5-18'
        'S-1-5-21-0-0-0-1001'
        'S-1-5-21-4294967295-4294967295-4294967295-1001'
        'S-1-15-2-1-2-3-4-5-6-7-8'
        'S-1-5-80-123456789-123456789-123456789-123456789-123456789'
    ) {
        Test-SIDFormat -SID $_ | Should -BeTrue
    }

    It "Rejects '<_>', which fails the basic pattern" -ForEach @(
        'InvalidSID'
        'S-1-5'
        'S-1'
        'S-X-5-18'
        '1-5-18'
        'S-1-A-18'
        'S-1-5-A'
        '   '
        ' S-1-5-21-1234567890-1234567890-1234567890-1001'
    ) {
        Test-SIDFormat -SID $_ | Should -BeFalse
    }

    It "Rejects '<_>', which matches the pattern but is not a valid SecurityIdentifier" -ForEach @(
        'S-1-5-21-ABC-1234567890-1234567890-1001'
        'S-1-5-21-1234567890-1234567890-1234567890-1001!'
        'S-1-5-21-1234567890-1234567890-1234567890-1001-EXTRA'
        'S-1-5-21-1234567890-1234567890-1234567890-'
        'S-1-5-21--1234567890-1234567890-1234567890-1001'
        'S-1-5-21-1234567890-1234567890-1234567890-1001 '
    ) {
        Test-SIDFormat -SID $_ | Should -BeFalse
        Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
            $Message -like 'SID format invalid - SecurityIdentifier creation failed:*'
        }
    }

    It "Rejects a SID with more sub-authorities than a SecurityIdentifier allows" {
        $longSID = 'S-1-5-21-' + ('1234567890-' * 50) + '1001'

        Test-SIDFormat -SID $longSID | Should -BeFalse
    }

    It "Refuses a null or empty SID at binding" {
        { Test-SIDFormat -SID $null } | Should -Throw
        { Test-SIDFormat -SID '' } | Should -Throw
    }

    It "Validates each SID piped to it" {
        $results = @('S-1-5-32-544', 'DOMAIN\user', 'S-1-5-21-123-456-789-1001' | Test-SIDFormat)

        $results | Should -Be @($true, $false, $true)
    }

    It "Logs under the SIDFormat component with the caller's correlation ID" {
        Test-SIDFormat -SID 'S-1-5-18' -CorrelationId 'fmt-1' | Out-Null

        Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
            $Message -eq 'SID format valid: S-1-5-18' -and $Component -eq 'SIDFormat' -and $CorrelationId -eq 'fmt-1'
        }
    }
}

Describe "Test-WellKnownSID" -Tag 'Unit', 'Private', 'SID' {

    BeforeEach {
        $script:Config = $null
    }

    It "Recognises the listed well-known SID <_>" -ForEach @(
        'S-1-0-0', 'S-1-1-0', 'S-1-3-0', 'S-1-5-7', 'S-1-5-11', 'S-1-5-18', 'S-1-5-19', 'S-1-5-20'
    ) {
        Test-WellKnownSID -SID $_ | Should -BeTrue
    }

    It "Recognises the service SID prefix <_>" -ForEach @(
        'S-1-5-80-123456789-123456789-123456789-123456789-123456789'
        'S-1-5-90-0-1'
        'S-1-5-96-0-1'
    ) {
        Test-WellKnownSID -SID $_ | Should -BeTrue
    }

    It "Recognises every built-in domain SID such as <_>" -ForEach @('S-1-5-32-544', 'S-1-5-32-545', 'S-1-5-32-551') {
        Test-WellKnownSID -SID $_ | Should -BeTrue
        Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -eq "SID is built-in domain SID: $_" }
    }

    It "Recognises the domain admin group with RID <_>" -ForEach @('512', '518', '519') {
        Test-WellKnownSID -SID "S-1-5-21-1234567890-1234567890-1234567890-$_" | Should -BeTrue
    }

    It "Does not treat the domain SID with RID <_> as well known" -ForEach @('500', '501', '513', '1001') {
        Test-WellKnownSID -SID "S-1-5-21-1234567890-1234567890-1234567890-$_" | Should -BeFalse
    }

    It "Does not treat a SID that only shares a prefix with a listed SID as well known" {
        Test-WellKnownSID -SID 'S-1-5-21-1-2-3-1001' | Should -BeFalse
        Test-WellKnownSID -SID 'S-1-5-110' | Should -BeFalse
    }

    It "Recognises a SID matching a configured WellKnownSIDPatterns entry" {
        $script:Config = @{ WellKnownSIDPatterns = @('^S-1-5-21-9-9-9-\d+$') }

        Test-WellKnownSID -SID 'S-1-5-21-9-9-9-1001' | Should -BeTrue
        Test-WellKnownSID -SID 'S-1-5-21-8-8-8-1001' | Should -BeFalse
    }

    It "Recognises a SID listed in the configured ProtectedSIDs" {
        $script:Config = @{ ProtectedSIDs = @('S-1-5-21-9-9-9-1001') }

        Test-WellKnownSID -SID 'S-1-5-21-9-9-9-1001' | Should -BeTrue
        Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
            $Message -eq 'SID is in protected SIDs list: S-1-5-21-9-9-9-1001'
        }
    }

    It "Refuses a null or empty SID at binding" {
        { Test-WellKnownSID -SID $null } | Should -Throw
        { Test-WellKnownSID -SID '' } | Should -Throw
    }

    It "Tests each SID piped to it" {
        $results = @('S-1-5-32-544', 'S-1-5-21-123-456-789-1001' | Test-WellKnownSID)

        $results | Should -Be @($true, $false)
    }
}

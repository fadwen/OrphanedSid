#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
<#
.SYNOPSIS
    Unit tests for the Get-StringHash utility function

.DESCRIPTION
    Tests Get-StringHash parameter validation and each hash algorithm against published test
    vectors and independently computed UTF-8 digests.

.NOTES
    Author: Jeffrey Stuhr
    Blog: https://www.techbyjeff.net
    LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/
#>

BeforeAll {
    $ModuleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    . "$ModuleRoot\Private\Utilities\Get-StringHash.ps1"
}

Describe "Get-StringHash" -Tag "Unit", "Private", "Utilities" {
    Context "Parameter Validation" {
        It "Should reject an empty string" {
            { Get-StringHash -InputString "" } | Should -Throw -ErrorId 'ParameterArgumentValidationErrorEmptyStringNotAllowed,Get-StringHash'
        }

        It "Should reject a null InputString" {
            { Get-StringHash -InputString $null } | Should -Throw -ErrorId 'ParameterArgumentValidationErrorEmptyStringNotAllowed,Get-StringHash'
        }

        It "Should reject an algorithm outside SHA256, SHA1 and MD5" {
            { Get-StringHash -InputString "test" -Algorithm "SHA512" } | Should -Throw -ErrorId 'ParameterArgumentValidationError,Get-StringHash'
        }
    }

    Context "Hash Algorithm Functionality" {
        # Published digests of the ASCII string "test"
        It "Should compute the <Algorithm> digest as uppercase hex without separators" -ForEach @(
            @{ Algorithm = 'SHA256'; Expected = '9F86D081884C7D659A2FEAA0C55AD015A3BF4F1B2B0B822CD15D6C15B0F00A08' }
            @{ Algorithm = 'SHA1'; Expected = 'A94A8FE5CCB19BA61C4C0873D391E987982FBBD3' }
            @{ Algorithm = 'MD5'; Expected = '098F6BCD4621D373CADE4E832627B4F6' }
        ) {
            Get-StringHash -InputString "test" -Algorithm $Algorithm | Should -BeExactly $Expected
        }

        It "Should use SHA256 when no algorithm is given" {
            Get-StringHash -InputString "test" | Should -BeExactly '9F86D081884C7D659A2FEAA0C55AD015A3BF4F1B2B0B822CD15D6C15B0F00A08'
        }

        It "Should hash the UTF-8 bytes of non-ASCII text" {
            # "cafe" with an acute e, followed by a CJK character; built from code points so the
            # file stays ASCII. The expected value is the SHA256 of the UTF-8 encoding, computed with
            # Get-FileHash over a BOM-less UTF-8 file.
            $text = 'caf' + [char]0x00E9 + [char]0x6D4B

            Get-StringHash -InputString $text | Should -BeExactly '784DE62200F22F024038A725BD76FD25851B44E4ADD3563BAA1427E16DF6A5DC'
        }

        It "Should hash line breaks as given without normalizing them" {
            # The SHA256 of the UTF-8 bytes of "Line1<CR><LF>Line2"
            $crlf = Get-StringHash -InputString "Line1`r`nLine2"
            $lf = Get-StringHash -InputString "Line1`nLine2"

            $crlf | Should -BeExactly 'E9DE6FF7F6ECEA086FDC878B35D4A226CB5099FCE7E5331C302A626978EDE8DF'
            $lf | Should -Not -Be $crlf
        }

        It "Should hash a whitespace-only string rather than treat it as empty" {
            # The SHA256 of three spaces
            Get-StringHash -InputString "   " | Should -BeExactly '0AAD7DA77D2ED59C396C99A74E49F3A4524DCDBCB5163251B1433D640247AEB4'
        }
    }
}

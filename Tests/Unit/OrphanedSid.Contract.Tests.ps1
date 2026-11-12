#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }

<#
.SYNOPSIS
    Contract tests for the OrphanedSid module as a whole.

.DESCRIPTION
    The unit tests dot-source one private file at a time, so they cannot see what happens when the
    root module loads every file into one scope. Two defects escaped them that way and were found
    only by running against a domain controller: two files defined Test-BackupIntegrity with
    different parameters, and the later definition silently replaced the one the restore path
    called; and a call site passed -DistinguishedName to a function whose parameter is -ObjectDN,
    which a mock with loose parameters accepted. These tests read the shipping files as an abstract
    syntax tree and fail on both patterns, and they are the one place the module is imported with
    -Force to assert what a fresh import exports.
#>

BeforeDiscovery {
    $script:ModuleRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
}

BeforeAll {
    $script:ModuleRoot = (Resolve-Path "$PSScriptRoot\..\..").Path

    # Every top-level function definition in the files the root module dot-sources. Class members
    # (constructors and methods) are FunctionDefinitionAst nodes too, and so is a fallback defined
    # inside an `if (-not (Get-Command ...))` guard; neither is a module function, so both are skipped.
    $script:Definitions = @{}
    $script:Duplicates = [System.Collections.Generic.List[string]]::new()
    $script:FileAsts = @{}
    $shippingFiles = Get-ChildItem -Path "$script:ModuleRoot\Classes", "$script:ModuleRoot\Private", "$script:ModuleRoot\Public" -Filter *.ps1 -Recurse -File
    foreach ($file in $shippingFiles) {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        $script:FileAsts[$file.FullName] = $ast
        $relative = $file.FullName.Substring($script:ModuleRoot.Length + 1)
        $functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        foreach ($function in $functions) {
            $parent = $function.Parent
            $skip = $false
            while ($parent) {
                if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst] -or
                    $parent -is [System.Management.Automation.Language.TypeDefinitionAst] -or
                    $parent -is [System.Management.Automation.Language.IfStatementAst]) {
                    $skip = $true
                    break
                }
                $parent = $parent.Parent
            }
            if ($skip) { continue }

            if ($script:Definitions.ContainsKey($function.Name)) {
                $first = $script:Definitions[$function.Name]
                $script:Duplicates.Add("$($function.Name) in $($first.File):$($first.Line) and ${relative}:$($function.Extent.StartLineNumber)")
            }
            $script:Definitions[$function.Name] = @{ File = $relative; Line = $function.Extent.StartLineNumber; Ast = $function }
        }
    }

    # Parameter names a function accepts: its own parameters and their aliases, the common
    # parameters, and -WhatIf/-Confirm when it declares SupportsShouldProcess.
    $script:CommonParameters = @([System.Management.Automation.PSCmdlet]::CommonParameters) +
        @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)
    function Get-AcceptedParameterName {
        param([System.Management.Automation.Language.FunctionDefinitionAst]$Function)

        $names = [System.Collections.Generic.List[string]]::new()
        $names.AddRange([string[]]$script:CommonParameters)
        $paramBlock = $Function.Body.ParamBlock
        if (-not $paramBlock) { return $names }
        foreach ($attribute in $paramBlock.Attributes) {
            if ($attribute.NamedArguments.ArgumentName -contains 'SupportsShouldProcess') {
                $names.Add('WhatIf')
                $names.Add('Confirm')
            }
        }
        foreach ($parameter in $paramBlock.Parameters) {
            $names.Add($parameter.Name.VariablePath.UserPath)
            foreach ($attribute in $parameter.Attributes) {
                if ($attribute -is [System.Management.Automation.Language.AttributeAst] -and $attribute.TypeName.Name -eq 'Alias') {
                    foreach ($alias in $attribute.PositionalArguments) { $names.Add($alias.Value) }
                }
            }
        }
        return $names
    }

    # Every call from one module function to another whose named parameters the callee does not
    # declare. PowerShell binds an unambiguous prefix, so -Correlation would bind -CorrelationId;
    # the check allows the same.
    $script:DriftedCalls = [System.Collections.Generic.List[string]]::new()
    foreach ($path in $script:FileAsts.Keys) {
        $relative = $path.Substring($script:ModuleRoot.Length + 1)
        $calls = $script:FileAsts[$path].FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)
        foreach ($call in $calls) {
            $name = $call.GetCommandName()
            if (-not $name -or -not $script:Definitions.ContainsKey($name)) { continue }
            $accepted = Get-AcceptedParameterName -Function $script:Definitions[$name].Ast
            foreach ($element in $call.CommandElements) {
                if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                $used = $element.ParameterName
                if (-not ($accepted | Where-Object { $_ -like "$used*" })) {
                    $script:DriftedCalls.Add("${relative}:$($call.Extent.StartLineNumber) passes -$used to $name, which declares no such parameter (defined in $($script:Definitions[$name].File))")
                }
            }
        }
    }
}

Describe 'OrphanedSid module contract' -Tag 'Unit', 'Contract' {

    Context 'Function definitions' {
        It 'Defines every function once across Classes, Private and Public' {
            # The root module dot-sources every file into one scope, so the last definition of a name
            # wins silently. Two Test-BackupIntegrity definitions with different parameters made every
            # restore fail with "A parameter cannot be found that matches parameter name 'BackupData'".
            $script:Duplicates | Should -BeNullOrEmpty -Because ($script:Duplicates -join '; ')
        }

        It 'Defines at least the three public commands and the private helpers they call' {
            $script:Definitions.Keys | Should -Contain 'Find-OrphanedSid'
            $script:Definitions.Keys | Should -Contain 'Remove-OrphanedSid'
            $script:Definitions.Keys | Should -Contain 'Restore-OrphanedSidBackup'
            $script:Definitions.Keys | Should -Contain 'Invoke-MainProcessingLogic'
        }
    }

    Context 'Calls between module functions' {
        It 'Names only parameters the callee declares' {
            # A unit test that mocks the callee with loose parameters accepts any name; the module does
            # not. Set-ModifiedACL passed -DistinguishedName to New-ACLBackup, whose parameter is
            # -ObjectDN, and every removal logged "ACL backup failed".
            $script:DriftedCalls | Should -BeNullOrEmpty -Because ($script:DriftedCalls -join '; ')
        }
    }

    Context 'Help references' {
        It 'Points every troubleshooting reference in the shipping files at a guide that exists (#101)' {
            # Help copied from a template named 81 guides that were never written; a maintainer
            # following one found nothing
            $shippingFiles = Get-ChildItem -Path "$script:ModuleRoot\Classes", "$script:ModuleRoot\Private", "$script:ModuleRoot\Public" -Filter *.ps1 -Recurse -File
            $missing = foreach ($match in ($shippingFiles | Select-String -Pattern '\.\\Troubleshooting\\[^\s''"`)]+\.md' -AllMatches)) {
                foreach ($reference in $match.Matches.Value) {
                    # The references are written with backslashes; the suite also runs on Linux
                    $relative = $reference.Substring(2).Replace('\', [System.IO.Path]::DirectorySeparatorChar)
                    if (-not (Test-Path -LiteralPath (Join-Path $script:ModuleRoot $relative) -PathType Leaf)) {
                        "$($match.Filename):$($match.LineNumber) $reference"
                    }
                }
            }
            @($missing) | Should -BeNullOrEmpty -Because (@($missing) -join '; ')
        }
    }

    Context 'Fresh import' {
        BeforeAll {
            Import-Module "$script:ModuleRoot\OrphanedSid.psd1" -Force
        }

        It 'Exports exactly the three public commands' {
            $exported = @((Get-Module OrphanedSid).ExportedFunctions.Keys | Sort-Object)
            $exported | Should -Be @('Find-OrphanedSid', 'Remove-OrphanedSid', 'Restore-OrphanedSidBackup')
        }

        It 'Resolves the restore path to the integrity check that takes backup data' {
            # Guards the fix above from the other side: the function the restore path calls by name
            # must be the one whose parameters it passes.
            $parameters = & (Get-Module OrphanedSid) { (Get-Command Test-BackupIntegrity).Parameters.Keys }
            $parameters | Should -Contain 'BackupData'
            $parameters | Should -Contain 'ExpectedObjectDN'
        }

        It 'Reports a SID whose directory lookups fail as Unverified, never as orphaned, and does not cache it' {
            # A failed lookup was once reported as orphaned and removed. This runs the loaded module's
            # own Test-OrphanedSID, Test-AccessRuleForOrphanedSID and New-OrphanedSIDResult together,
            # so a change to any of their contracts shows here even when each unit test still passes.
            # The public commands import the ActiveDirectory module first, which defines the
            # not-found exception type the catch clauses name; without RSAT the stub defines it.
            . "$script:ModuleRoot\Tests\TestHelpers\ADCmdletStubs.ps1"
            Mock Write-StructuredLog { } -ModuleName OrphanedSid
            Mock Invoke-ADOperationWithRetry { throw 'Unable to contact the server. The server is not operational' } -ModuleName OrphanedSid

            $outcome = & (Get-Module OrphanedSid) {
                $sid = 'S-1-5-21-3623811015-3361044348-30300820-9013'
                $script:SIDValidationCache = @{}
                $rule = [PSCustomObject]@{
                    IdentityReference     = [System.Security.Principal.SecurityIdentifier]$sid
                    ActiveDirectoryRights = 'GenericRead'
                    AccessControlType     = 'Allow'
                }
                [PSCustomObject]@{
                    Lookup = Test-OrphanedSID -SID $sid
                    Result = Test-AccessRuleForOrphanedSID -AccessRule $rule -ObjectDN 'CN=Share,DC=contoso,DC=com'
                    Cached = $script:SIDValidationCache.ContainsKey($sid)
                }
            }

            $outcome.Lookup.Status | Should -Be 'Unverified'
            $outcome.Lookup.IsOrphaned | Should -BeFalse
            $outcome.Lookup.ErrorMessage | Should -BeLike '*Get-ADObject:*not operational*'
            $outcome.Result.VerificationStatus | Should -Be 'Unverified'
            $outcome.Result.VerificationError | Should -BeLike '*not operational*'
            $outcome.Cached | Should -BeFalse
        }
    }
}

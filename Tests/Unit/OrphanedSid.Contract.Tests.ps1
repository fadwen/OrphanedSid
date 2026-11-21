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
    $script:FileTokens = @{}
    $shippingFiles = Get-ChildItem -Path "$script:ModuleRoot\Classes", "$script:ModuleRoot\Private", "$script:ModuleRoot\Public" -Filter *.ps1 -Recurse -File
    foreach ($file in $shippingFiles) {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        $script:FileAsts[$file.FullName] = $ast
        $script:FileTokens[$file.FullName] = $tokens
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

    Context 'Classes' {
        It 'Declares no static member in any class (#125)' {
            # On Windows PowerShell 5.1 a static method of a PowerShell class fails with a
            # NullReferenceException once another runspace of the process has imported the module
            # and been closed. An instance and its methods keep working. A host application with a
            # runspace pool reaches that state, and no test in this process can: closing a second
            # runspace here would break every later test that uses the class.
            $classes = @(foreach ($path in $script:FileAsts.Keys) {
                    $script:FileAsts[$path].FindAll(
                        { param($node) $node -is [System.Management.Automation.Language.TypeDefinitionAst] }, $true)
                })
            $static = @(foreach ($class in $classes) {
                    foreach ($member in $class.Members) {
                        if ($member.IsStatic) {
                            "$($class.Name).$($member.Name)"
                        }
                    }
                })

            $classes.Count | Should -BeGreaterThan 0
            $static | Should -BeNullOrEmpty -Because ($static -join '; ')
        }

        It 'Calls no function of the module from a class (#159)' {
            # The test files that dot-source a class define it a second time, outside the
            # module. Measured on PowerShell 7 with a method that called a private function: when
            # a test file imports the module, a second one dot-sources the class and a third then
            # runs the module, the method fails with the function not recognized. In declaration
            # order that does not happen, and in CI, which shuffles, four of eight jobs failed. A
            # method that calls cmdlets only cannot fail that way.
            $calls = @(foreach ($path in $script:FileAsts.Keys) {
                    $relative = $path.Substring($script:ModuleRoot.Length + 1)
                    $classes = $script:FileAsts[$path].FindAll(
                        { param($node) $node -is [System.Management.Automation.Language.TypeDefinitionAst] }, $true)
                    foreach ($class in $classes) {
                        $commands = $class.FindAll(
                            { param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)
                        foreach ($command in $commands) {
                            $name = $command.GetCommandName()
                            if ($name -and $script:Definitions.ContainsKey($name)) {
                                "$name at ${relative}:$($command.Extent.StartLineNumber)"
                            }
                        }
                    }
                })

            $calls | Should -BeNullOrEmpty -Because ($calls -join '; ')
        }
    }

    Context 'Terminating errors raised with throw or Write-Error -ErrorAction Stop (#130)' {
        BeforeAll {
            # Every throw statement and every Write-Error ... -ErrorAction Stop that an advanced
            # function of Private or Public runs. One inside a script block that the function hands
            # to a command, such as ForEach-Object or a retry, is counted too: under a caller's
            # -ErrorAction SilentlyContinue it is swallowed like one written directly in the function,
            # which was measured on both editions. A class method has no $PSCmdlet, and the script
            # block of an attribute, such as a ValidateScript, reports a bad value by throwing; these
            # two are not counted. -ErrorAction is matched in both of its spellings, with a space and
            # with a colon. A Write-Error that takes it from a splatted hashtable is not seen.
            $script:OldFormStatements = @(foreach ($path in $script:FileAsts.Keys) {
                    $relative = $path.Substring($script:ModuleRoot.Length + 1)
                    if ($relative -like 'Classes*') {
                        continue
                    }
                    $nodes = $script:FileAsts[$path].FindAll({
                            param($node)
                            $node -is [System.Management.Automation.Language.ThrowStatementAst] -or
                            ($node -is [System.Management.Automation.Language.CommandAst] -and
                                $node.GetCommandName() -eq 'Write-Error' -and
                                $node.Extent.Text -match '-(ErrorAction|EA)(\s+|:\s*)[''"]?Stop')
                        }, $true)
                    foreach ($node in $nodes) {
                        $inAttribute = $false
                        $owner = $node.Parent
                        while ($null -ne $owner -and
                            $owner -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) {
                            if ($owner -is [System.Management.Automation.Language.AttributeAst]) {
                                $inAttribute = $true
                            }
                            $owner = $owner.Parent
                        }
                        if ($null -eq $owner -or $inAttribute) {
                            continue
                        }
                        # [CmdletBinding()] makes a function advanced, and so does a [Parameter()]
                        # attribute on one of its parameters
                        $paramBlock = $owner.Body.ParamBlock
                        $isAdvanced = $false
                        if ($null -ne $paramBlock) {
                            $attributeNames = @($paramBlock.Attributes | ForEach-Object { $_.TypeName.Name }) +
                                @($paramBlock.Parameters | ForEach-Object { $_.Attributes } |
                                        ForEach-Object { $_.TypeName.Name })
                            $isAdvanced = @($attributeNames |
                                    Where-Object { $_ -in 'CmdletBinding', 'Parameter' }).Count -gt 0
                        }
                        if (-not $isAdvanced) {
                            continue
                        }
                        # DOC-22 of the standards: a departure from a rule is recorded in a comment
                        # directly above the statement, as "# Exception to <rule ID>: <reason>"
                        $sourceLines = [System.IO.File]::ReadAllLines($path)
                        $above = $node.Extent.StartLineNumber - 2
                        $recordsException = $false
                        while ($above -ge 0 -and $sourceLines[$above] -match '^\s*#') {
                            if ($sourceLines[$above] -match '^\s*# Exception to ERR-11: \S') {
                                $recordsException = $true
                            }
                            $above--
                        }
                        [PSCustomObject]@{
                            Place = "${relative}:$($node.Extent.StartLineNumber)"
                            File = $relative
                            # The form of the six catch lines of the public commands; see CLAUDE.md
                            PassesErrorRecord = $node -is [System.Management.Automation.Language.CommandAst] -and
                                $node.Extent.Text -match '-ErrorRecord\b'
                            RecordsException = $recordsException
                        }
                    }
                })
        }

        It 'Keeps the recorded exception to the six catch lines of the three public commands' {
            # Write-Error -ErrorRecord $_ -ErrorAction Stop in the catch of begin and of end. CLAUDE.md,
            # "A fatal error of a public command ends the calling script, against ERR-11", says why
            # these lines are an exception and that it covers nothing else.
            $exceptions = @($script:OldFormStatements | Where-Object PassesErrorRecord)

            $exceptions.Count | Should -Be 6 -Because ($exceptions.Place -join '; ')
            @($exceptions | Group-Object -Property File).Count | Should -Be 3
            @($exceptions | Where-Object { $_.File -notlike 'Public*' }).Count | Should -Be 0
        }

        It 'Records the exception in a comment directly above each of the six lines' {
            $exceptions = @($script:OldFormStatements | Where-Object PassesErrorRecord)
            $unrecorded = @($exceptions | Where-Object { -not $_.RecordsException } | ForEach-Object { $_.Place })

            $exceptions.Count | Should -Be 6
            $unrecorded | Should -BeNullOrEmpty -Because "no '# Exception to ERR-11:' comment is above: $($unrecorded -join '; ')"
        }

        It 'Calls every function that raises with ThrowTerminatingError from inside a try' {
            # An error raised with ThrowTerminatingError() goes to the nearest try on the call stack.
            # With none there, it ends only the statement that called the function, and the caller
            # carries on with its next line. So that each function is right whatever calls it, every
            # call to a function that raises this way is in a try body, and a new call outside one
            # fails here.
            #
            # A call inside a script block takes the try that the block is written in when the block
            # is handed straight to a command, as the retry blocks are. Measured on both editions:
            # while the command runs the block, that try is still on the call stack and catches the
            # error, whether or not the command has a try of its own. A block that is kept, in a
            # variable for one, can run after that try has ended, where nothing catches the error;
            # a try outside such a block does not count. A command that stores the block it is
            # handed and runs it later cannot be seen here.
            $raising =@($script:Definitions.Keys | Where-Object {
                    $script:Definitions[$_].Ast.Extent.Text -match '\$PSCmdlet\.ThrowTerminatingError\('
                })
            $outside = @(foreach ($path in $script:FileAsts.Keys) {
                    $relative = $path.Substring($script:ModuleRoot.Length + 1)
                    $calls = $script:FileAsts[$path].FindAll({
                            param($node)
                            $node -is [System.Management.Automation.Language.CommandAst] -and
                            $node.GetCommandName() -in $raising
                        }, $true)
                    foreach ($call in $calls) {
                        $inTry = $false
                        $inKeptBlock = $false
                        $previous = $call
                        $owner = $call.Parent
                        while ($null -ne $owner -and
                            $owner -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) {
                            if ($owner -is [System.Management.Automation.Language.TryStatementAst] -and
                                $owner.Body -eq $previous -and -not $inKeptBlock) {
                                $inTry = $true
                            }
                            if ($owner -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -and
                                $owner.Parent -isnot [System.Management.Automation.Language.CommandAst]) {
                                $inKeptBlock = $true
                            }
                            $previous = $owner
                            $owner = $owner.Parent
                        }
                        if (-not $inTry) {
                            "$($call.GetCommandName()) at ${relative}:$($call.Extent.StartLineNumber)"
                        }
                    }
                })

            $raising.Count | Should -BeGreaterThan 5
            $outside | Should -BeNullOrEmpty -Because ($outside -join '; ')
        }

        It 'Has no other such statement' {
            # ERR-11 of the standards: an advanced function ends with $PSCmdlet.ThrowTerminatingError().
            # A throw, or a Write-Error -ErrorAction Stop without -ErrorRecord, that is added to an
            # advanced function of Private or Public fails here. CLAUDE.md, under the heading for
            # ERR-11, says what to write in its place and what to check in the function first.
            $others = @($script:OldFormStatements | Where-Object { -not $_.PassesErrorRecord })

            $others.Count | Should -Be 0 -Because "such a statement is at: $($others.Place -join '; ')"
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
        It 'Points every reference to a guide or a document in the shipping files at a file that exists (#101, #188)' {
            # Help copied from a template named 81 guides that were never written; a maintainer
            # following one found nothing. Three references into Documentation were to files that
            # had moved to its archive or had never been there.
            $shippingFiles = Get-ChildItem -Path "$script:ModuleRoot\Classes", "$script:ModuleRoot\Private", "$script:ModuleRoot\Public" -Filter *.ps1 -Recurse -File
            $missing = foreach ($match in ($shippingFiles | Select-String -Pattern '\.\\(Troubleshooting|Documentation)\\[^\s''"`)]+\.md' -AllMatches)) {
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

        It 'Holds no <What> in the shipping files (#<Issue>)' -ForEach @(
            # Help written before the module had measurements or its present name. A maintainer
            # reads it as fact: a rate of 50 to 200 objects a second stood where 8 was measured.
            @{ Issue = 158; What = 'section of performance figures'; Pattern = 'PERFORMANCE CHARACTERISTICS' }
            @{ Issue = 158; What = 'version line in help'; Pattern = '^\s*#?\s*Version:\s*\d' }
            @{ Issue = 158; What = 'date of a last update'; Pattern = '^\s*#?\s*Last Updated:' }
            @{ Issue = 158; What = 'mention of the old name Find-UnknownSID'; Pattern = 'Find-UnknownSID' }
            # Claims made in words. Nothing shows that the module was checked against a regulation
            # or a requirement, and what a function is worth to a business is not what it does.
            # The help says what the code does: that a security entry is written whatever the log
            # level is, not that this meets an audit requirement.
            @{ Issue = 176; What = 'section of business value'; Pattern = 'BUSINESS VALUE' }
            @{ Issue = 176; What = 'use of the word enterprise-grade'; Pattern = 'enterprise-grade' }
            @{ Issue = 176; What = 'claim of compliance'; Pattern = 'complian' }
            @{ Issue = 176; What = 'name of a regulation'; Pattern = '\b(SOX|GDPR|HIPAA)\b' }
        ) {
            $folders = "$script:ModuleRoot\Classes", "$script:ModuleRoot\Private", "$script:ModuleRoot\Public"
            $shippingFiles = Get-ChildItem -Path $folders -Filter *.ps1 -Recurse -File
            $found = @($shippingFiles | Select-String -Pattern $Pattern |
                    ForEach-Object { "$($_.Filename):$($_.LineNumber)" })

            $found | Should -BeNullOrEmpty -Because ($found -join '; ')
        }

        It 'Has no help block above the first function of a file (#176)' {
            # Get-Help reads the block inside the function. A second block at the top of the file
            # is read by people only, and nothing keeps the two alike: such blocks listed
            # Logging.ps1 and Classes.ps1 as dependencies when neither file existed any more.
            $commentKind = [System.Management.Automation.Language.TokenKind]::Comment
            $stray = foreach ($path in ($script:FileAsts.Keys | Sort-Object)) {
                $relative = $path.Substring($script:ModuleRoot.Length + 1)
                if ($relative -notmatch '^(Private|Public)[\\/]') { continue }

                $firstFunction = $script:FileAsts[$path].Find(
                    { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
                if ($null -eq $firstFunction) { continue }

                foreach ($token in $script:FileTokens[$path]) {
                    if ($token.Kind -eq $commentKind -and
                        $token.Extent.EndOffset -le $firstFunction.Extent.StartOffset -and
                        $token.Text -match '(?m)^\s*(<#)?\s*#?\s*\.(SYNOPSIS|DESCRIPTION|NOTES)\b') {
                        "${relative}:$($token.Extent.StartLineNumber)"
                    }
                }
            }

            @($stray) | Should -BeNullOrEmpty -Because (@($stray) -join '; ')
        }
    }

    Context 'The pattern for the attribute that names a component (#134)' {
        It 'Is the same in the validator and in the three checks on the restore path' {
            # The class of an object sets the attribute that names it, so the four places that check
            # the start of a name take any attribute. When one of them accepts less than the others,
            # an object is reported and never cleaned, or backed up and never restored. The unit
            # tests dot-source these files one at a time, so the pattern is written out in each of
            # them and compared here.
            $isString = {
                param($node)
                $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
            }
            $assignment = $script:Definitions['Test-ValidDistinguishedName'].Ast.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left.Extent.Text -eq '$attributeName'
                }, $true)
            $assignment | Should -Not -BeNullOrEmpty
            $pattern = $assignment.Right.Find($isString, $true).Value
            # A pattern that came out empty would be found in every string
            $pattern | Should -Match '^\(.+\)$'

            $different = @(foreach ($name in 'Invoke-RestoreWorkflow', 'Get-RestorationTarget', 'Test-BackupIntegrity') {
                    $holders = @($script:Definitions[$name].Ast.FindAll($isString, $true) |
                            Where-Object { $_.Value.Contains("^$pattern=") })
                    if ($holders.Count -eq 0) {
                        "$name in $($script:Definitions[$name].File)"
                    }
                })

            $different | Should -BeNullOrEmpty -Because "no string there starts with ^$pattern= : $($different -join '; ')"
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

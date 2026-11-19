#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

# Each command here runs in a process of its own, as the last statement but one of a script that
# has no try around it unless the test writes one. Pester runs every test inside a try, and
# inside a try a throw raised during start-up propagates whatever the caller's error action is.
# A command called directly from a test therefore behaves correctly even when a command called
# from a prompt or a scheduled script does not.
#
# A second runspace in this process would be cheaper and is not usable: on Windows PowerShell 5.1,
# once another runspace has imported the module and been closed, the static method
# [ScriptConfiguration]::LoadFromFile() fails in this one with a NullReferenceException, and every
# later test that passes -ConfigPath fails with it.

BeforeAll {
    $script:RepositoryRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..\..')).Path
    $script:HostPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

    # The script the new process runs. The module is imported unchanged; the directory is a set of
    # global functions, which the module's calls resolve to. The last line is reached only when the
    # command did not end the script.
    $script:Template = @'
. <<STUBS>>
Import-Module -Name <<MANIFEST>>

function global:Get-ADDomain {
    [PSCustomObject]@{
        DistinguishedName = 'DC=lab,DC=test'
        DomainSID = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-21-1111111111-2222222222-3333333333')
    }
}

function global:Get-ADObject {
    param($Identity, $Filter, $LDAPFilter, $SearchBase, $SearchScope, $Properties, $ResultPageSize,
        [switch]$IncludeDeletedObjects, $Server)
    [System.IO.File]::AppendAllText(<<READS>>, "read`r`n")
}

# The session helper asks whether the ActiveDirectory module is installed and imports it.
function global:Get-Module {
    [CmdletBinding()]
    param([Parameter(Position = 0)]$Name, [switch]$ListAvailable, [switch]$All)
    if ($Name -eq 'ActiveDirectory') {
        return [PSCustomObject]@{ Name = 'ActiveDirectory' }
    }
    Microsoft.PowerShell.Core\Get-Module @PSBoundParameters
}

function global:Import-Module {
    [CmdletBinding()]
    param([Parameter(Position = 0)]$Name, [switch]$Force, [switch]$PassThru)
    if ($Name -eq 'ActiveDirectory') {
        return
    }
    Microsoft.PowerShell.Core\Import-Module @PSBoundParameters
}

<<FAULT>>
Set-Location -LiteralPath <<WORK>>
<<COMMAND>>
[System.IO.File]::WriteAllText(<<REACHED>>, 'reached')
'@

    # A path as a single-quoted literal for the generated script, with any quote in it doubled
    function ConvertTo-Literal {
        param(
            [Parameter(Mandatory)]
            [string]$Text
        )

        "'" + $Text.Replace("'", "''") + "'"
    }

    function Invoke-InNewProcess {
        param(
            [Parameter(Mandatory)]
            [string]$Command,

            [string]$Fault = '',

            # Runs the script the way a pipeline agent runs an inline step: dot-sourced from -Command
            [switch]$AsCommand
        )

        $readsFile = Join-Path -Path $script:WorkFolder -ChildPath 'directory-reads.txt'
        $reachedFile = Join-Path -Path $script:WorkFolder -ChildPath 'reached-the-end.txt'
        $scriptFile = Join-Path -Path $script:WorkFolder -ChildPath 'run.ps1'
        $outputFile = Join-Path -Path $script:WorkFolder -ChildPath 'output.txt'
        $errorFile = Join-Path -Path $script:WorkFolder -ChildPath 'errors.txt'

        $stubs = Join-Path -Path $script:RepositoryRoot -ChildPath 'Tests\TestHelpers\ADCmdletStubs.ps1'
        $manifest = Join-Path -Path $script:RepositoryRoot -ChildPath 'OrphanedSid.psd1'
        $text = $script:Template.Replace('<<STUBS>>', (ConvertTo-Literal -Text $stubs))
        $text = $text.Replace('<<MANIFEST>>', (ConvertTo-Literal -Text $manifest))
        $text = $text.Replace('<<READS>>', (ConvertTo-Literal -Text $readsFile))
        $text = $text.Replace('<<REACHED>>', (ConvertTo-Literal -Text $reachedFile))
        $text = $text.Replace('<<WORK>>', (ConvertTo-Literal -Text $script:WorkFolder))
        $text = $text.Replace('<<FAULT>>', $Fault).Replace('<<COMMAND>>', $Command)
        [System.IO.File]::WriteAllText($scriptFile, $text, [System.Text.UTF8Encoding]::new($true))

        $hostArguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass')
        if ($AsCommand) {
            $hostArguments += '-Command', "`". $(ConvertTo-Literal -Text $scriptFile)`""
        } else {
            $hostArguments += '-File', "`"$scriptFile`""
        }
        $startParameters = @{
            FilePath = $script:HostPath
            ArgumentList = $hostArguments
            RedirectStandardOutput = $outputFile
            RedirectStandardError = $errorFile
            NoNewWindow = $true
            Wait = $true
            PassThru = $true
        }
        $process = Start-Process @startParameters

        $directoryReads = 0
        if (Test-Path -LiteralPath $readsFile) {
            $directoryReads = @(Get-Content -LiteralPath $readsFile).Count
        }

        [PSCustomObject]@{
            ExitCode = $process.ExitCode
            # True when the script carried on after the command
            ReachedEnd = Test-Path -LiteralPath $reachedFile
            Text = [System.IO.File]::ReadAllText($outputFile) + [System.IO.File]::ReadAllText($errorFile)
            DirectoryReads = $directoryReads
        }
    }
}

Describe 'A public command whose session cannot start' -Tag 'Integration', 'Public' {
    BeforeEach {
        $script:WorkFolder = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $script:BackupFolder = Join-Path -Path $script:WorkFolder -ChildPath 'Backup'
        $null = New-Item -Path $script:BackupFolder -ItemType Directory -Force
        $script:LogFile = Join-Path -Path $script:WorkFolder -ChildPath 'run.log'

        # "Info" is not one of the six level names, so the file loads and then fails validation.
        $script:InvalidConfig = Join-Path -Path $script:WorkFolder -ChildPath 'invalid.json'
        Set-Content -LiteralPath $script:InvalidConfig -Value '{ "LogLevel": "Info" }' -Encoding ascii
        $script:ValidConfig = Join-Path -Path $script:WorkFolder -ChildPath 'valid.json'
        Set-Content -LiteralPath $script:ValidConfig -Value '{ "LogLevel": "Warning" }' -Encoding ascii

        $script:LogLiteral = ConvertTo-Literal -Text $script:LogFile
        $script:BackupLiteral = ConvertTo-Literal -Text $script:BackupFolder
        $script:Common = "-SearchBase 'OU=Finance,DC=lab,DC=test' -LogPath $script:LogLiteral -SuppressConsoleOutput"
    }

    Context 'Core Functionality' {
        It 'Reads the directory and lets the script carry on when the configuration file is valid' {
            $config = ConvertTo-Literal -Text $script:ValidConfig
            $command = "Find-OrphanedSid $script:Common -ConfigPath $config -ErrorAction SilentlyContinue"

            $run = Invoke-InNewProcess -Command $command

            $run.ReachedEnd | Should-BeTrue
            $run.ExitCode | Should-Be 0
            $run.DirectoryReads | Should-BeGreaterThan 0
        }
    }

    Context 'Error Handling' {
        It '<CommandName> ends the script with the configuration error and reads nothing from the directory, with <Handling>' -ForEach @(
            @{ CommandName = 'Find-OrphanedSid'; Prefix = ''; Suffix = ''; Handling = 'the default error action' }
            @{
                CommandName = 'Find-OrphanedSid'; Prefix = ''; Suffix = ' -ErrorAction SilentlyContinue'
                Handling = '-ErrorAction SilentlyContinue'
            }
            @{
                CommandName = 'Find-OrphanedSid'; Prefix = '$ErrorActionPreference = ''SilentlyContinue''; '; Suffix = ''
                Handling = 'a session preference of SilentlyContinue'
            }
            @{ CommandName = 'Remove-OrphanedSid'; Prefix = ''; Suffix = ''; Handling = 'the default error action' }
            @{
                CommandName = 'Remove-OrphanedSid'; Prefix = ''; Suffix = ' -ErrorAction SilentlyContinue'
                Handling = '-ErrorAction SilentlyContinue'
            }
            @{
                CommandName = 'Remove-OrphanedSid'; Prefix = '$ErrorActionPreference = ''SilentlyContinue''; '; Suffix = ''
                Handling = 'a session preference of SilentlyContinue'
            }
        ) {
            $extra = ''
            if ($CommandName -eq 'Remove-OrphanedSid') {
                $extra = " -Force -BackupPath $script:BackupLiteral"
            }
            $config = ConvertTo-Literal -Text $script:InvalidConfig
            $command = "$Prefix$CommandName $script:Common -ConfigPath $config$extra$Suffix"

            $run = Invoke-InNewProcess -Command $command

            $run.ReachedEnd | Should-BeFalse
            $run.ExitCode | Should-Be 1
            $run.Text | Should-BeLikeString '*Configuration validation failed*'
            # Before the fix the caller was shown an error from a later stage instead: the first
            # statistics counter, which was $null.
            ($run.Text -like '*cannot be found on this object*') | Should-BeFalse
            $run.DirectoryReads | Should-Be 0
        }

        It '<CommandName> ends the script when -SearchBase holds no usable name, under -ErrorAction SilentlyContinue' -ForEach @(
            @{ CommandName = 'Find-OrphanedSid'; Extra = '' }
            @{ CommandName = 'Remove-OrphanedSid'; Extra = ' -Force' }
        ) {
            # That check is in the end block, inside the try whose catch raises the failure, so it
            # was never swallowed. This passes with or without the fix, and keeps it that way.
            $command = "$CommandName -SearchBase 42 -LogPath $script:LogLiteral -SuppressConsoleOutput$Extra " +
                '-ErrorAction SilentlyContinue'

            $run = Invoke-InNewProcess -Command $command

            $run.ReachedEnd | Should-BeFalse
            $run.ExitCode | Should-Be 1
            $run.Text | Should-BeLikeString '*No usable search base in the input*'
            $run.DirectoryReads | Should-Be 0
        }

        It 'Hands the error to a catch around the call and lets the script carry on' {
            # Documentation/Automation.md names try and catch as the way to handle a critical error.
            $config = ConvertTo-Literal -Text $script:InvalidConfig
            $command = "try { Find-OrphanedSid $script:Common -ConfigPath $config } " +
                'catch { ''CAUGHT: '' + $_.Exception.Message }'

            $run = Invoke-InNewProcess -Command $command

            $run.ReachedEnd | Should-BeTrue
            $run.ExitCode | Should-Be 0
            $run.Text | Should-BeLikeString '*CAUGHT: Configuration validation failed*'
            $run.DirectoryReads | Should-Be 0
        }

        It 'Ends a script that is run through -Command, with exit code 1' {
            $config = ConvertTo-Literal -Text $script:InvalidConfig
            $command = "Find-OrphanedSid $script:Common -ConfigPath $config"

            $run = Invoke-InNewProcess -Command $command -AsCommand

            $run.ReachedEnd | Should-BeFalse
            $run.ExitCode | Should-Be 1
            $run.Text | Should-BeLikeString '*Configuration validation failed*'
            $run.DirectoryReads | Should-Be 0
        }

        It 'Restore-OrphanedSidBackup ends the script with the start-up error under -ErrorAction SilentlyContinue' {
            # Restore-OrphanedSidBackup takes no configuration file, so its start-up is made to
            # fail by replacing one private function in the new process's copy of the module.
            $fault = '& (Get-Module -Name OrphanedSid) { ' +
                'function script:Initialize-LoggingSystem { throw ''The logging system could not start'' } }'
            $command = "Restore-OrphanedSidBackup -TargetObjectDN 'OU=Finance,DC=lab,DC=test' " +
                "-BackupPath $script:BackupLiteral -LogPath $script:LogLiteral -SuppressConsoleOutput -Force " +
                '-ErrorAction SilentlyContinue'

            $run = Invoke-InNewProcess -Command $command -Fault $fault

            $run.ReachedEnd | Should-BeFalse
            $run.ExitCode | Should-Be 1
            $run.Text | Should-BeLikeString '*The logging system could not start*'
            $run.DirectoryReads | Should-Be 0
        }
    }
}

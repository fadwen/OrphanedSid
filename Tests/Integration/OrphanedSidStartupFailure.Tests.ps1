#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

# Each command here runs in a runspace of its own, with no try above the call. Pester runs every
# test inside a try, and inside a try a throw raised during start-up propagates whatever the
# caller's error action is. A command called directly from a test therefore behaves correctly
# even when a command called from a prompt or a scheduled script does not.

BeforeAll {
    $script:RepositoryRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..\..')).Path

    # Runs in the new runspace before the command. The module is imported unchanged; the
    # directory is a set of global functions, which the module's calls resolve to.
    $script:Setup = {
        param($RepositoryRoot)

        . (Join-Path -Path $RepositoryRoot -ChildPath 'Tests\TestHelpers\ADCmdletStubs.ps1')
        Import-Module -Name (Join-Path -Path $RepositoryRoot -ChildPath 'OrphanedSid.psd1')

        $global:DirectoryReads = 0

        function global:Get-ADDomain {
            [PSCustomObject]@{
                DistinguishedName = 'DC=lab,DC=test'
                DomainSID = [System.Security.Principal.SecurityIdentifier]::new(
                    'S-1-5-21-1111111111-2222222222-3333333333')
            }
        }

        function global:Get-ADObject {
            param($Identity, $Filter, $LDAPFilter, $SearchBase, $SearchScope, $Properties, $ResultPageSize,
                [switch]$IncludeDeletedObjects, $Server)
            $global:DirectoryReads++
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
    }.ToString()

    function Invoke-InNewRunspace {
        param(
            [Parameter(Mandatory)]
            [string]$Script,

            [string]$Fault
        )

        $shell = [powershell]::Create()
        try {
            $null = $shell.AddScript($script:Setup).AddArgument($script:RepositoryRoot).Invoke()
            if ($Fault) {
                $shell.Commands.Clear()
                $null = $shell.AddScript($Fault).Invoke()
            }

            # Loading the stand-ins records lookups of commands that do not exist; start clean.
            $shell.Commands.Clear()
            $null = $shell.AddScript('$global:Error.Clear()').Invoke()
            $shell.Streams.Error.Clear()

            $shell.Commands.Clear()
            $null = $shell.AddScript($Script)
            # What the caller is shown: an error that ends the script is raised by Invoke(), with
            # its message one level in, and one that ends only the command is on the error stream.
            $shown = [System.Collections.Generic.List[string]]::new()
            $ended = $false
            try {
                $null = $shell.Invoke()
            } catch {
                $ended = $true
                $shown.Add($_.Exception.InnerException.Message)
            }
            foreach ($record in $shell.Streams.Error) {
                $shown.Add($record.Exception.Message)
            }

            # What the session recorded, shown or not. The record of the stop itself has no message.
            $shell.Commands.Clear()
            $readErrors = '$global:Error | ForEach-Object { $_.Exception.Message } | Where-Object { $_ }'
            $recorded = @($shell.AddScript($readErrors).Invoke())
            $shell.Commands.Clear()
            $directoryReads = $shell.AddScript('$global:DirectoryReads').Invoke()[0]

            [PSCustomObject]@{
                # True when the error ended the calling script, not only the command
                Ended = $ended
                Shown = $shown.ToArray()
                Recorded = [string[]]$recorded
                DirectoryReads = $directoryReads
            }
        } finally {
            $shell.Dispose()
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

        $script:Common = "-SearchBase 'OU=Finance,DC=lab,DC=test' -LogPath '$script:LogFile' -SuppressConsoleOutput"
    }

    Context 'Core Functionality' {
        It 'Reads the directory when the configuration file is valid' {
            $script = "Set-Location -LiteralPath '$script:WorkFolder'; " +
                "Find-OrphanedSid $script:Common -ConfigPath '$script:ValidConfig' -ErrorAction SilentlyContinue"

            $run = Invoke-InNewRunspace -Script $script

            $run.Shown | Should-BeCollection -Count 0
            $run.Ended | Should-BeFalse
            $run.DirectoryReads | Should-BeGreaterThan 0
        }
    }

    Context 'Error Handling' {
        It '<CommandName> ends with the configuration error and reads nothing from the directory, with <Handling>' -ForEach @(
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
                $extra = " -Force -BackupPath '$script:BackupFolder'"
            }
            $script = "Set-Location -LiteralPath '$script:WorkFolder'; $Prefix" +
                "$CommandName $script:Common -ConfigPath '$script:InvalidConfig'$extra$Suffix"

            $run = Invoke-InNewRunspace -Script $script

            $run.Shown | Should-BeCollection -Count 1
            $run.Shown[0] | Should-BeLikeString '*Configuration validation failed*'
            # Nothing from a later stage: before the fix the session recorded a second error, from
            # the first statistics counter, and that was the one the caller was shown.
            $run.Recorded | Should-All { $_ -like '*Configuration validation failed*' }
            $run.Ended | Should-BeTrue
            $run.DirectoryReads | Should-Be 0
        }

        It 'Restore-OrphanedSidBackup ends with the start-up error under -ErrorAction SilentlyContinue' {
            # Restore-OrphanedSidBackup takes no configuration file, so its start-up is made to
            # fail by replacing one private function in the new runspace's copy of the module.
            $fault = '& (Get-Module -Name OrphanedSid) { ' +
                'function script:Initialize-LoggingSystem { throw ''The logging system could not start'' } }'
            $script = "Set-Location -LiteralPath '$script:WorkFolder'; " +
                "Restore-OrphanedSidBackup -TargetObjectDN 'OU=Finance,DC=lab,DC=test' " +
                "-BackupPath '$script:BackupFolder' -LogPath '$script:LogFile' -SuppressConsoleOutput -Force " +
                '-ErrorAction SilentlyContinue'

            $run = Invoke-InNewRunspace -Script $script -Fault $fault

            $run.Shown | Should-BeCollection -Count 1
            $run.Shown[0] | Should-BeLikeString '*The logging system could not start*'
            $run.Ended | Should-BeTrue
            $run.DirectoryReads | Should-Be 0
        }
    }
}

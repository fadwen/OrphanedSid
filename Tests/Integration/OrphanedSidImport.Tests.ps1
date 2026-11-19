#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

# Each import here is of a copy of the module, in a process of its own. Importing a second copy
# into the Pester process would define the module's classes again beside the ones the other tests
# use, and a damaged copy has to be imported the way a user imports it: with nothing around the
# call that changes how an error in the root module travels.

BeforeAll {
    $script:RepositoryRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..\..')).Path
    $script:HostPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

    function New-ModuleCopy {
        $folder = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $copy = Join-Path -Path $folder -ChildPath 'OrphanedSid'
        $null = New-Item -Path $copy -ItemType Directory -Force
        foreach ($item in 'Classes', 'Private', 'Public', 'OrphanedSid.psd1', 'OrphanedSid.psm1') {
            $source = Join-Path -Path $script:RepositoryRoot -ChildPath $item
            Copy-Item -LiteralPath $source -Destination $copy -Recurse
        }

        $copy
    }

    function Invoke-ImportInNewProcess {
        param(
            [Parameter(Mandatory)]
            [string]$ModuleFolder
        )

        $workFolder = Split-Path -Path $ModuleFolder -Parent
        $exportedFile = Join-Path -Path $workFolder -ChildPath 'exported.txt'
        $messageFile = Join-Path -Path $workFolder -ChildPath 'message.txt'
        $scriptFile = Join-Path -Path $workFolder -ChildPath 'import.ps1'
        $outputFile = Join-Path -Path $workFolder -ChildPath 'output.txt'
        $errorFile = Join-Path -Path $workFolder -ChildPath 'errors.txt'
        $manifest = Join-Path -Path $ModuleFolder -ChildPath 'OrphanedSid.psd1'

        # One file is written only when the module is loaded afterwards, with what it exports. The
        # other holds the message of the last error, read from $Error and not from the console,
        # which wraps and colours a long message.
        $lines = @(
            "Import-Module -Name '$manifest'"
            '$module = Get-Module -Name OrphanedSid'
            'if ($module) {'
            '    $names = @($module.ExportedFunctions.Keys | Sort-Object) -join '','''
            "    [System.IO.File]::WriteAllText('$exportedFile', `$names)"
            '}'
            'if ($Error.Count -gt 0) {'
            "    [System.IO.File]::WriteAllText('$messageFile', `$Error[0].Exception.Message)"
            '}'
        )
        [System.IO.File]::WriteAllText($scriptFile, ($lines -join "`r`n"), [System.Text.UTF8Encoding]::new($true))

        $startParameters = @{
            FilePath = $script:HostPath
            ArgumentList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptFile`"")
            RedirectStandardOutput = $outputFile
            RedirectStandardError = $errorFile
            NoNewWindow = $true
            Wait = $true
            PassThru = $true
        }
        $null = Start-Process @startParameters

        $exported = $null
        if (Test-Path -LiteralPath $exportedFile) {
            $exported = [System.IO.File]::ReadAllText($exportedFile)
        }
        $message = $null
        if (Test-Path -LiteralPath $messageFile) {
            $message = [System.IO.File]::ReadAllText($messageFile)
        }

        [PSCustomObject]@{
            # $null when the module was not loaded after the import
            Exported = $exported
            # $null when the import recorded no error
            Message = $message
        }
    }
}

Describe 'Importing the module' -Tag 'Integration', 'Module' {
    Context 'Core Functionality' {
        It 'Imports an intact copy and exports the three commands' {
            $copy = New-ModuleCopy

            $run = Invoke-ImportInNewProcess -ModuleFolder $copy

            $run.Exported | Should-Be 'Find-OrphanedSid,Remove-OrphanedSid,Restore-OrphanedSidBackup'
            $run.Message | Should-BeNull
        }
    }

    Context 'Error Handling' {
        It 'Fails, naming the file, when one file does not parse' {
            $copy = New-ModuleCopy
            $broken = Join-Path -Path $copy -ChildPath 'Private\SID\Test-SIDFormat.ps1'
            Set-Content -LiteralPath $broken -Value "function Test-SIDFormat {`r`n    param(" -Encoding ascii

            $run = Invoke-ImportInNewProcess -ModuleFolder $copy

            $run.Exported | Should-BeNull
            $run.Message | Should-BeLikeString "OrphanedSid cannot be imported: '*Test-SIDFormat.ps1' failed to load.*"
        }

        It 'Fails, naming the folder, when <Folder> is missing' -ForEach @(
            @{ Folder = 'Classes' }
            @{ Folder = 'Public' }
            @{ Folder = 'Private' }
            @{ Folder = 'Private\Reporting' }
        ) {
            $copy = New-ModuleCopy
            Remove-Item -LiteralPath (Join-Path -Path $copy -ChildPath $Folder) -Recurse -Force

            $run = Invoke-ImportInNewProcess -ModuleFolder $copy

            $run.Exported | Should-BeNull
            $run.Message | Should-BeLikeString "OrphanedSid cannot be imported: the folder '*$Folder*' is missing.*"
        }
    }
}

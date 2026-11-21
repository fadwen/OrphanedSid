#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

<#
.SYNOPSIS
    Unit tests for Initialize-BackupFolder, which creates the folder that backups are written to
    and confirms that it exists.

.DESCRIPTION
    Tests the real function against the real file system, in the test drive. Nothing is mocked:
    what the function is for is the two cases in which New-Item itself does not stop, and a mock
    of New-Item cannot show them.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\..\Private\Backup\Initialize-BackupFolder.ps1"

    $script:errorId = 'BackupFolderNotCreated,Initialize-BackupFolder'
}

Describe 'Initialize-BackupFolder' -Tag 'Unit', 'Backup', 'Private' {

    BeforeEach {
        # A folder of its own for each test; the test drive lasts for the whole Describe
        $script:root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $null = New-Item -Path $script:root -ItemType Directory
    }

    Context 'Parameter Validation' {
        It 'Declares Path as a mandatory string' {
            Get-Command -Name Initialize-BackupFolder |
                Should-HaveParameter -ParameterName Path -Type ([string]) -Mandatory
        }

        It 'Supports -WhatIf' {
            (Get-Command -Name Initialize-BackupFolder).Parameters.ContainsKey('WhatIf') | Should-BeTrue
        }
    }

    Context 'Core Functionality' {
        It 'Creates a folder that is missing and returns True' {
            $folder = Join-Path -Path $script:root -ChildPath 'Backup'

            $result = Initialize-BackupFolder -Path $folder -ErrorAction Stop

            $result | Should-HaveType ([bool])
            $result | Should-BeTrue
            Test-Path -LiteralPath $folder -PathType Container | Should-BeTrue
        }

        It 'Creates the folders above it as well' {
            $folder = Join-Path -Path $script:root -ChildPath 'Backup\20260101_120000'

            $result = Initialize-BackupFolder -Path $folder -ErrorAction Stop

            $result | Should-BeTrue
            Test-Path -LiteralPath $folder -PathType Container | Should-BeTrue
        }

        It 'Creates a folder whose name holds square brackets, under that name' {
            $folder = Join-Path -Path $script:root -ChildPath 'Run [1]'

            $result = Initialize-BackupFolder -Path $folder -ErrorAction Stop

            $result | Should-BeTrue
            $names = @(Get-ChildItem -LiteralPath $script:root -Directory | ForEach-Object { $_.Name })
            $names | Should-BeCollection -Count 1
            $names[0] | Should-BeString 'Run [1]' -CaseSensitive
        }

        It 'Returns False for a folder that is already there, and leaves what it holds' {
            $folder = Join-Path -Path $script:root -ChildPath 'Backup'
            $null = New-Item -Path $folder -ItemType Directory
            $file = Join-Path -Path $folder -ChildPath 'earlier.xml'
            Set-Content -LiteralPath $file -Value 'kept' -Encoding ascii

            $result = Initialize-BackupFolder -Path $folder -ErrorAction Stop

            $result | Should-BeFalse
            Get-Content -LiteralPath $file -Raw | Should-BeString 'kept' -TrimWhitespace
        }

        It 'Creates nothing, returns False and raises nothing under -WhatIf' {
            $folder = Join-Path -Path $script:root -ChildPath 'Backup'

            $result = Initialize-BackupFolder -Path $folder -WhatIf -ErrorAction Stop

            $result | Should-BeFalse
            Test-Path -LiteralPath $folder | Should-BeFalse
        }
    }

    Context 'Error Handling' {
        It 'Ends with BackupFolderNotCreated when a part of the path is a file' {
            # New-Item -Force returns nothing and reports no error here, with -ErrorAction Stop too
            $file = Join-Path -Path $script:root -ChildPath 'a-file.txt'
            Set-Content -LiteralPath $file -Value 'x' -Encoding ascii
            $folder = Join-Path -Path $file -ChildPath 'Backup'

            $errorRecord = { Initialize-BackupFolder -Path $folder } |
                Should-Throw -FullyQualifiedErrorId $script:errorId -ExceptionType ([System.IO.IOException])

            $errorRecord.TargetObject | Should-BeString $folder
            $errorRecord.Exception.Message | Should-BeLikeString "*'$folder'*may be a file*"
            $errorRecord.CategoryInfo.Category |
                Should-Be ([System.Management.Automation.ErrorCategory]::WriteError)
        }

        It 'Ends with BackupFolderNotCreated when the path is a file itself' {
            $file = Join-Path -Path $script:root -ChildPath 'Backup'
            Set-Content -LiteralPath $file -Value 'x' -Encoding ascii

            { Initialize-BackupFolder -Path $file } |
                Should-Throw -FullyQualifiedErrorId $script:errorId -ExceptionType ([System.IO.IOException])

            Test-Path -LiteralPath $file -PathType Leaf | Should-BeTrue
            Get-Content -LiteralPath $file -Raw | Should-BeString 'x' -TrimWhitespace
        }

        It 'Ends with BackupFolderNotCreated, and the reason, when the parent denies new folders' {
            # New-Item only writes its error here; without -ErrorAction Stop it is not caught
            $parent = Join-Path -Path $script:root -ChildPath 'NoNewFolders'
            $null = New-Item -Path $parent -ItemType Directory
            $folder = Join-Path -Path $parent -ChildPath 'Backup'
            $account = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            # AD: add a subfolder. WD: add a file.
            $null = & icacls.exe $parent /deny "${account}:(AD,WD)"
            $LASTEXITCODE | Should-Be 0

            try {
                $errorRecord = { Initialize-BackupFolder -Path $folder } |
                    Should-Throw -FullyQualifiedErrorId $script:errorId -ExceptionType ([System.IO.IOException])
            } finally {
                # Tidiness only: the entry does not keep the folder from being removed with the
                # test drive
                $null = & icacls.exe $parent /remove:d $account
            }

            $errorRecord.Exception.InnerException |
                Should-HaveType ([System.UnauthorizedAccessException])
            $errorRecord.Exception.Message |
                Should-BeLikeString "*'$folder'*$($errorRecord.Exception.InnerException.Message)*"
            Test-Path -LiteralPath $folder | Should-BeFalse
        }

        It 'Raises the error also when the caller asks to continue silently' {
            $file = Join-Path -Path $script:root -ChildPath 'a-file.txt'
            Set-Content -LiteralPath $file -Value 'x' -Encoding ascii
            $folder = Join-Path -Path $file -ChildPath 'Backup'

            { Initialize-BackupFolder -Path $folder -ErrorAction SilentlyContinue } |
                Should-Throw -FullyQualifiedErrorId $script:errorId
        }
    }
}

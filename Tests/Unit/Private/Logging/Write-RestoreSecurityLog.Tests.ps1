#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\..\Private\Logging\Write-RestoreSecurityLog.ps1')

    # Pester mocks only a command that exists. The real function is in another file, and its
    # parameters are the ones named here.
    function Write-SecurityLog {
        [CmdletBinding()]
        param($SecurityEventType, $Message, $Outcome, [hashtable]$SecurityContext, $CorrelationId)
    }

    $script:ObjectName = 'OU=Finance,DC=contoso,DC=com'
    $script:FileName = 'C:\Backup\20261120_101500\OU_Finance_DC_contoso_DC_com_20261120_101501.xml'
}

Describe 'Write-RestoreSecurityLog' -Tag 'Unit', 'Private' {
    BeforeEach {
        Mock -CommandName Write-SecurityLog -MockWith { }
        Mock -CommandName Write-Warning -MockWith { }
    }

    Context 'Parameter Validation' {
        It 'Declares <ParameterName> as a mandatory parameter' -ForEach @(
            @{ ParameterName = 'Outcome' }
            @{ ParameterName = 'Message' }
            @{ ParameterName = 'TargetObjectDN' }
            @{ ParameterName = 'BackupFile' }
        ) {
            Get-Command -Name Write-RestoreSecurityLog |
                Should-HaveParameter -ParameterName $ParameterName -Type ([string]) -Mandatory
        }

        It 'Refuses an outcome other than Attempt, Success and Failure' {
            $call = {
                Write-RestoreSecurityLog -Outcome 'Done' -Message 'x' -TargetObjectDN $script:ObjectName -BackupFile $script:FileName
            }

            $call | Should-Throw -ExceptionType ([System.Management.Automation.ParameterBindingException])
            Should-Invoke -CommandName Write-SecurityLog -Times 0 -Exactly
        }
    }

    Context 'Core Functionality' {
        It 'Writes a PrivilegeUse entry with the outcome <Outcome> and the message it was given' -ForEach @(
            @{ Outcome = 'Attempt' }
            @{ Outcome = 'Success' }
            @{ Outcome = 'Failure' }
        ) {
            $entry = @{
                Outcome = $Outcome
                Message = 'ACL restore operation'
                TargetObjectDN = $script:ObjectName
                BackupFile = $script:FileName
                CorrelationId = 'run-1'
            }

            Write-RestoreSecurityLog @entry

            # The case's value has its own name here: inside the filter, $Outcome is the
            # parameter of the mock
            $expectedOutcome = $entry['Outcome']
            Should-Invoke -CommandName Write-SecurityLog -Times 1 -Exactly -ParameterFilter {
                $SecurityEventType -eq 'PrivilegeUse' -and $Outcome -eq $expectedOutcome -and
                $Message -eq 'ACL restore operation' -and $CorrelationId -eq 'run-1'
            }
        }

        It 'Puts the operation, the object and the backup file into the entry' {
            Write-RestoreSecurityLog -Outcome Attempt -Message 'x' -TargetObjectDN $script:ObjectName -BackupFile $script:FileName

            Should-Invoke -CommandName Write-SecurityLog -Times 1 -Exactly -ParameterFilter {
                $SecurityContext['Operation'] -eq 'RestoreACL' -and
                $SecurityContext['TargetObjectDN'] -eq $script:ObjectName -and
                $SecurityContext['BackupFile'] -eq $script:FileName
            }
        }

        It 'Adds what Detail holds, and lets it replace a value of the same name' {
            $detail = @{ EntriesRestored = 12; Operation = 'RestoreACLFromFile' }

            Write-RestoreSecurityLog -Outcome Success -Message 'x' -TargetObjectDN $script:ObjectName -BackupFile $script:FileName -Detail $detail

            Should-Invoke -CommandName Write-SecurityLog -Times 1 -Exactly -ParameterFilter {
                $SecurityContext['EntriesRestored'] -eq 12 -and
                $SecurityContext['Operation'] -eq 'RestoreACLFromFile' -and
                $SecurityContext['TargetObjectDN'] -eq $script:ObjectName
            }
        }

        It 'Says in the entry that the run is a preview when the caller runs under -WhatIf' {
            $WhatIfPreference = $true

            Write-RestoreSecurityLog -Outcome Attempt -Message 'x' -TargetObjectDN $script:ObjectName -BackupFile $script:FileName

            Should-Invoke -CommandName Write-SecurityLog -Times 1 -Exactly -ParameterFilter {
                $SecurityContext['WhatIfMode'] -is [bool] -and $SecurityContext['WhatIfMode']
            }
        }

        It 'Says in the entry that the run is not a preview otherwise' {
            Write-RestoreSecurityLog -Outcome Attempt -Message 'x' -TargetObjectDN $script:ObjectName -BackupFile $script:FileName

            Should-Invoke -CommandName Write-SecurityLog -Times 1 -Exactly -ParameterFilter {
                $SecurityContext['WhatIfMode'] -is [bool] -and -not $SecurityContext['WhatIfMode']
            }
        }

        It 'Leaves the correlation ID to Write-SecurityLog when it has <What>' -ForEach @(
            @{ What = 'none'; Entry = @{} }
            @{ What = 'an empty one'; Entry = @{ CorrelationId = '' } }
            @{ What = 'only blanks'; Entry = @{ CorrelationId = '   ' } }
        ) {
            Write-RestoreSecurityLog @Entry -Outcome Attempt -Message 'x' -TargetObjectDN $script:ObjectName -BackupFile $script:FileName

            Should-Invoke -CommandName Write-SecurityLog -Times 1 -Exactly -ParameterFilter {
                -not $PesterBoundParameters.ContainsKey('CorrelationId')
            }
        }

        It 'Writes nothing to the pipeline' {
            $output = @(Write-RestoreSecurityLog -Outcome Attempt -Message 'x' -TargetObjectDN $script:ObjectName -BackupFile $script:FileName)

            $output | Should-BeCollection -Count 0
        }
    }

    Context 'Error Handling' {
        It 'Warns and returns when the entry cannot be written, so that the restore keeps its own result' {
            Mock -CommandName Write-SecurityLog -MockWith { throw 'The log file is locked' }
            $call = {
                Write-RestoreSecurityLog -Outcome Success -Message 'x' -TargetObjectDN $script:ObjectName -BackupFile $script:FileName -ErrorAction Stop
            }

            & $call

            Should-Invoke -CommandName Write-Warning -Times 1 -Exactly -ParameterFilter {
                $Message -like "*$($script:ObjectName)*could not be written*The log file is locked*"
            }
        }

        It 'Asks Write-SecurityLog to stop on an error, so that a failure reaches the warning' {
            Write-RestoreSecurityLog -Outcome Attempt -Message 'x' -TargetObjectDN $script:ObjectName -BackupFile $script:FileName

            Should-Invoke -CommandName Write-SecurityLog -Times 1 -Exactly -ParameterFilter {
                $PesterBoundParameters['ErrorAction'] -eq 'Stop'
            }
        }
    }
}

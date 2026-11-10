#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

<#
.SYNOPSIS
    Pester tests for the Start-OrchestrationWorkflow private function

.DESCRIPTION
    Covers routing of each operation type to Invoke-MainProcessingLogic or Invoke-RestoreWorkflow,
    the parameters each delegate receives, correlation ID handling, logging, and error handling.
    Both delegates are mocked.

.NOTES
    Author: Jeffrey Stuhr
    Blog: https://www.techbyjeff.net
    LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/
    PowerShell Version: 5.1+
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\..\Private\Core\Start-OrchestrationWorkflow.ps1"

    # Placeholders so the delegates can be mocked. The parameters are the real functions' names,
    # so a key the orchestrator splats that the real function lacks also fails to bind here.
    function Write-StructuredLog { param($Message, $Level, $Component, $CorrelationId) }
    function Invoke-MainProcessingLogic {
        [CmdletBinding(SupportsShouldProcess)]
        param($SearchBase, [switch]$Remove, [switch]$IncludeInherited, $MaxRetries, $BackupPath, $CorrelationId)
    }
    function Invoke-RestoreWorkflow {
        [CmdletBinding(SupportsShouldProcess)]
        param($BackupPath, $TargetObjectDN, [switch]$VerifyRestoration, $CorrelationId)
    }

    $script:SearchBase = 'OU=TestUsers,DC=contoso,DC=com'
    $script:TargetDN = 'CN=TestUser,OU=Users,DC=contoso,DC=com'
    $script:BackupPath = 'C:\TestBackups\run1'
}

Describe "Start-OrchestrationWorkflow" -Tag 'Unit', 'Core', 'Private' {

    BeforeEach {
        $script:CorrelationId = [System.Guid]::NewGuid().ToString()
        Mock Write-StructuredLog { }
        Mock Invoke-MainProcessingLogic { @{ Source = 'MainProcessing'; Remove = [bool]$Remove } }
        Mock Invoke-RestoreWorkflow { @{ Source = 'Restore' } }
    }

    Context "Parameter validation" {
        It "Rejects an unknown OperationType" {
            { Start-OrchestrationWorkflow -OperationType 'Purge' -Parameters @{} } |
                Should -Throw -ExpectedMessage '*OperationType*'
            Should -Invoke Invoke-MainProcessingLogic -Times 0 -Exactly
            Should -Invoke Invoke-RestoreWorkflow -Times 0 -Exactly
        }

        It "Rejects a null Parameters hashtable" {
            { Start-OrchestrationWorkflow -OperationType 'Discovery' -Parameters $null } |
                Should -Throw -ExpectedMessage '*Parameters*'
        }
    }

    Context "Discovery" {
        It "Splats the parameters to Invoke-MainProcessingLogic without Remove and returns its result" {
            $parameters = @{ SearchBase = $script:SearchBase; MaxRetries = 5; IncludeInherited = $true; BackupPath = 'C:\B' }

            $result = Start-OrchestrationWorkflow -OperationType 'Discovery' -Parameters $parameters -CorrelationId $script:CorrelationId

            $result.Source | Should -Be 'MainProcessing'
            $result.Remove | Should -Be $false
            Should -Invoke Invoke-MainProcessingLogic -Times 1 -Exactly -ParameterFilter {
                $SearchBase -eq $script:SearchBase -and $MaxRetries -eq 5 -and $IncludeInherited -and
                $BackupPath -eq 'C:\B' -and $CorrelationId -eq $script:CorrelationId -and -not $Remove
            }
            Should -Invoke Invoke-RestoreWorkflow -Times 0 -Exactly
        }

        It "Adds its own CorrelationId to the parameters when they carry none" {
            $parameters = @{ SearchBase = $script:SearchBase }

            Start-OrchestrationWorkflow -OperationType 'Discovery' -Parameters $parameters -CorrelationId $script:CorrelationId | Out-Null

            $parameters.CorrelationId | Should -Be $script:CorrelationId
            Should -Invoke Invoke-MainProcessingLogic -Times 1 -Exactly -ParameterFilter { $CorrelationId -eq $script:CorrelationId }
        }

        It "Generates a GUID CorrelationId when neither the caller nor the parameters supply one" {
            $parameters = @{ SearchBase = $script:SearchBase }

            Start-OrchestrationWorkflow -OperationType 'Discovery' -Parameters $parameters | Out-Null

            $parameters.CorrelationId | Should -Match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            Should -Invoke Invoke-MainProcessingLogic -Times 1 -Exactly -ParameterFilter { $CorrelationId -eq $parameters.CorrelationId }
        }

        It "Keeps a CorrelationId already in the parameters" {
            $existing = [System.Guid]::NewGuid().ToString()
            $parameters = @{ SearchBase = $script:SearchBase; CorrelationId = $existing }

            Start-OrchestrationWorkflow -OperationType 'Discovery' -Parameters $parameters -CorrelationId $script:CorrelationId | Out-Null

            Should -Invoke Invoke-MainProcessingLogic -Times 1 -Exactly -ParameterFilter { $CorrelationId -eq $existing }
        }

        It "Passes WhatIf through to Invoke-MainProcessingLogic" {
            $parameters = @{ SearchBase = $script:SearchBase; WhatIf = $true }

            Start-OrchestrationWorkflow -OperationType 'Discovery' -Parameters $parameters | Out-Null

            Should -Invoke Invoke-MainProcessingLogic -Times 1 -Exactly -ParameterFilter { $WhatIf -eq $true }
        }
    }

    Context "Removal" {
        It "Adds Remove to the parameters and splats them to Invoke-MainProcessingLogic" {
            $parameters = @{ SearchBase = $script:SearchBase; BackupPath = $script:BackupPath }

            $result = Start-OrchestrationWorkflow -OperationType 'Removal' -Parameters $parameters -CorrelationId $script:CorrelationId

            $result.Remove | Should -Be $true
            $parameters.Remove | Should -Be $true
            Should -Invoke Invoke-MainProcessingLogic -Times 1 -Exactly -ParameterFilter {
                $Remove -and $SearchBase -eq $script:SearchBase -and $BackupPath -eq $script:BackupPath -and
                $CorrelationId -eq $script:CorrelationId
            }
        }
    }

    Context "Restore" {
        It "Maps the target, backup path and correlation ID and always asks for verification" {
            $parameters = @{ TargetObjectDN = $script:TargetDN; BackupPath = $script:BackupPath; CorrelationId = $script:CorrelationId }

            $result = Start-OrchestrationWorkflow -OperationType 'Restore' -Parameters $parameters

            $result.Source | Should -Be 'Restore'
            Should -Invoke Invoke-RestoreWorkflow -Times 1 -Exactly -ParameterFilter {
                $TargetObjectDN -eq $script:TargetDN -and $BackupPath -eq $script:BackupPath -and
                $CorrelationId -eq $script:CorrelationId -and $VerifyRestoration -and -not $WhatIf
            }
            Should -Invoke Invoke-MainProcessingLogic -Times 0 -Exactly
        }

        It "Drops keys the restore workflow does not take" {
            $parameters = @{ BackupPath = $script:BackupPath; SearchBase = $script:SearchBase; MaxRetries = 2 }

            # The placeholder has no SearchBase or MaxRetries parameter, so passing them would fail to bind
            { Start-OrchestrationWorkflow -OperationType 'Restore' -Parameters $parameters } | Should -Not -Throw

            Should -Invoke Invoke-RestoreWorkflow -Times 1 -Exactly -ParameterFilter {
                $BackupPath -eq $script:BackupPath -and $null -eq $TargetObjectDN
            }
        }

        It "Passes WhatIf only when it is true" {
            Start-OrchestrationWorkflow -OperationType 'Restore' -Parameters @{ BackupPath = $script:BackupPath; WhatIf = $true } | Out-Null
            Start-OrchestrationWorkflow -OperationType 'Restore' -Parameters @{ BackupPath = $script:BackupPath; WhatIf = $false } | Out-Null

            Should -Invoke Invoke-RestoreWorkflow -Times 1 -Exactly -ParameterFilter { $WhatIf -eq $true }
            Should -Invoke Invoke-RestoreWorkflow -Times 1 -Exactly -ParameterFilter { -not $WhatIf }
        }

        It "Adds the orchestrator's CorrelationId when the parameters carry none" {
            Start-OrchestrationWorkflow -OperationType 'Restore' -Parameters @{ BackupPath = $script:BackupPath } -CorrelationId $script:CorrelationId | Out-Null

            Should -Invoke Invoke-RestoreWorkflow -Times 1 -Exactly -ParameterFilter { $CorrelationId -eq $script:CorrelationId }
        }
    }

    Context "Logging" {
        It "Logs start, coordination and completion for <OperationType> with the correlation ID" -ForEach @(
            @{ OperationType = 'Discovery'; Coordination = 'Coordinating discovery workflow' }
            @{ OperationType = 'Removal'; Coordination = 'Coordinating removal workflow' }
            @{ OperationType = 'Restore'; Coordination = 'Coordinating restore workflow' }
        ) {
            Start-OrchestrationWorkflow -OperationType $OperationType -Parameters @{ BackupPath = $script:BackupPath } -CorrelationId $script:CorrelationId | Out-Null

            Should -Invoke Write-StructuredLog -Times 3 -Exactly
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq "Starting orchestration workflow: $OperationType" -and $Level -eq 'Information' -and
                $Component -eq 'Orchestration' -and $CorrelationId -eq $script:CorrelationId
            }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq $Coordination -and $Level -eq 'Debug' -and $CorrelationId -eq $script:CorrelationId
            }
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq "Orchestration workflow completed: $OperationType" -and $Level -eq 'Information' -and
                $CorrelationId -eq $script:CorrelationId
            }
        }
    }

    Context "Errors" {
        It "Logs an Error naming the operation and rethrows when <OperationType> fails" -ForEach @(
            @{ OperationType = 'Discovery' }
            @{ OperationType = 'Removal' }
            @{ OperationType = 'Restore' }
        ) {
            Mock Invoke-MainProcessingLogic { throw 'AD connection timeout' }
            Mock Invoke-RestoreWorkflow { throw 'AD connection timeout' }

            { Start-OrchestrationWorkflow -OperationType $OperationType -Parameters @{ BackupPath = $script:BackupPath } -CorrelationId $script:CorrelationId } |
                Should -Throw -ExpectedMessage 'AD connection timeout'

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Error' -and
                $Message -eq "Orchestration workflow failed for $OperationType : AD connection timeout" -and
                $CorrelationId -eq $script:CorrelationId
            }
        }

        It "Still logs completion from the finally block when the delegate throws" {
            Mock Invoke-MainProcessingLogic { throw 'boom' }

            { Start-OrchestrationWorkflow -OperationType 'Discovery' -Parameters @{} -CorrelationId $script:CorrelationId } | Should -Throw

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'Orchestration workflow completed: Discovery' -and $CorrelationId -eq $script:CorrelationId
            }
        }
    }
}

#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
#Requires -Version 5.1

<#
.SYNOPSIS
    Unit tests for Get-OrphanedSidModuleVersion.

.DESCRIPTION
    Backups, result metadata and the log header carried three different hard-coded version numbers
    (#52). The helper reads the version of the module it runs in, so it is tested both inside the
    imported module, where it must match the manifest, and dot-sourced, where there is no module.
#>

BeforeAll {
    $script:ManifestPath = Join-Path $PSScriptRoot '..\..\..\..\OrphanedSid.psd1'
    $script:ManifestVersion = (Import-PowerShellDataFile -Path $script:ManifestPath).ModuleVersion
    if (-not (Get-Module -Name OrphanedSid)) {
        . "$PSScriptRoot\..\..\..\TestHelpers\ADCmdletStubs.ps1"
        Import-Module $script:ManifestPath
    }
}

Describe 'Get-OrphanedSidModuleVersion' -Tag 'Unit', 'Private', 'Utilities' {
    It 'Returns the manifest version inside the module' {
        $version = & (Get-Module -Name OrphanedSid) { Get-OrphanedSidModuleVersion }

        $version | Should -Be $script:ManifestVersion
    }

    It 'Stamps result metadata with the manifest version inside the module' {
        $context = & (Get-Module -Name OrphanedSid) {
            $result = [OrphanedSIDResult]::new()
            Add-ProcessingMetadata -Result $result -CorrelationId 'mv-1'
            $result.ProcessingContext
        }

        $context.ModuleVersion | Should -Be $script:ManifestVersion
    }

    It "Returns 'unknown' when dot-sourced outside a module" {
        . "$PSScriptRoot\..\..\..\..\Private\Utilities\Get-OrphanedSidModuleVersion.ps1"

        Get-OrphanedSidModuleVersion | Should -Be 'unknown'
    }
}

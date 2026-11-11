function Get-OrphanedSidModuleVersion {
    <#
    .SYNOPSIS
        Returns the version of the loaded OrphanedSid module.

    .DESCRIPTION
        Backups, result metadata and the log header record the version that produced them. They
        once carried three different hard-coded numbers (1.0.0, 2.0.0 and 2.1.0), none of them the
        module's. This reads ModuleVersion from the module the function was loaded into, so the
        value follows the manifest.

        When the file is dot-sourced outside the module, as unit tests do, there is no module to
        read, and the function returns 'unknown' rather than a number that could be mistaken for
        a real one.

    .OUTPUTS
        [string] The module version, such as '1.0.1', or 'unknown'.

    .EXAMPLE
        PS> & (Get-Module OrphanedSid) { Get-OrphanedSidModuleVersion }

        DESCRIPTION: Reads the version of the imported module
        OUTPUT: '1.0.1'
        USE CASE: Stamping a backup file or a log header with the version that wrote it

    .NOTES
        Author: Jeffrey Stuhr
        Blog: https://www.techbyjeff.net
        LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # The session state a module function runs in belongs to its module; a dot-sourced copy has none
    $module = $ExecutionContext.SessionState.Module
    if ($module -and $module.Version) {
        return $module.Version.ToString()
    }
    return 'unknown'
}

function Export-ResultCsv {
    <#
    .SYNOPSIS
    Writes result objects to a CSV file whose first line is the header.

    .DESCRIPTION
    Windows PowerShell 5.1 writes a #TYPE line at the top of a CSV file unless Export-Csv is
    given -NoTypeInformation. PowerShell 6 and later write no such line, and from PowerShell 7.7
    the switch is obsolete: it has no effect, and each call that passes it writes a warning. The
    switch is therefore passed on Windows PowerShell only, so that the file starts with the header
    on every edition and a run with -OutputPath shows no warning that the user did not cause.

    The file is written with the encoding UTF8 of Export-Csv, and a file that is already there
    is replaced. A file that cannot be written ends the function with the error of Export-Csv as
    a terminating error.

    Under -WhatIf nothing is written.

    .PARAMETER InputObject
    The objects to write. Each one becomes a row.

    .PARAMETER LiteralPath
    Path of the CSV file. Wildcard characters are not expanded.

    .EXAMPLE
    Export-ResultCsv -InputObject $results -LiteralPath 'C:\Reports\orphaned.csv'

    Writes one row for each result. The first line of the file holds the property names.

    .EXAMPLE
    Export-ResultCsv -InputObject @($results | Select-Object -Property ObjectDN, Success) -LiteralPath $path

    Writes two columns of each result.

    .INPUTS
    None.

    .OUTPUTS
    None.

    .NOTES
    AUTHOR:
    - Author: Jeffrey Stuhr
    - Blog: https://techbyjeff.net
    - LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/
    - Bluesky: https://bsky.app/profile/techbyjeff.net
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [object[]]$InputObject,

        [Parameter(Mandatory)]
        [string]$LiteralPath
    )

    $exportParameters = @{
        LiteralPath = $LiteralPath
        Encoding = 'UTF8'
        # The question is asked once, by ShouldProcess below
        Confirm = $false
        ErrorAction = 'Stop'
    }
    if ($PSVersionTable.PSVersion -lt [version]'6.0') {
        # Windows PowerShell 5.1 writes a #TYPE line unless this switch is passed. It is not
        # passed elsewhere: PowerShell 7.7 writes a warning for it.
        $exportParameters['NoTypeInformation'] = $true
    }

    if ($PSCmdlet.ShouldProcess($LiteralPath, 'Export results to CSV')) {
        try {
            $InputObject | Export-Csv @exportParameters
        } catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }
    }
}

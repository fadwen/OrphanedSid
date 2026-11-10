<#
.SYNOPSIS
    Defines placeholder ActiveDirectory cmdlets when the RSAT module is not installed.

.DESCRIPTION
    Pester can only mock a command that already exists, and it builds the mock from that command's
    parameter metadata. Every test that mocks an ActiveDirectory cmdlet therefore fails with
    "Could not find Command Get-ADObject" on a machine without RSAT, and a stub with only a
    catch-all parameter would bind -SearchBase and -Filter into that catch-all so a mock body's
    named parameters stay empty. Dot-source this file before the first Mock: the cmdlets exist as
    global functions whose parameters match the ones the module and the tests use, and they throw
    if a test ever reaches them unmocked.

    Nothing is defined when the real module is available, so the stubs never shadow it.

.EXAMPLE
    . "$PSScriptRoot\..\..\TestHelpers\ADCmdletStubs.ps1"
    Mock Get-ADObject { @() }

.NOTES
    Author: Jeffrey Stuhr
    Blog: https://www.techbyjeff.net
    LinkedIn: https://www.linkedin.com/in/jeffrey-stuhr-034214aa/
#>

# Parameter lists are the subset of each cmdlet's parameters that the module or a test passes.
# Add to a list when a new call site uses a parameter that is not here.
$adCmdletStubs = @{
    'Get-ADDomain'           = '$Identity, $Current, $Server, $Credential'
    'Get-ADDomainController' = '$Identity, $Filter, $Discover, $Server, $Credential'
    'Get-ADObject'           = '$Identity, $Filter, $LDAPFilter, $SearchBase, $SearchScope, $Properties, $ResultPageSize, $ResultSetSize, [switch]$IncludeDeletedObjects, $Server, $Credential'
    'Set-ADObject'           = '$Identity, $Replace, $Add, $Remove, $Clear, $Server, $Credential, $PassThru'
    'Remove-ADObject'        = '$Identity, $Recursive, $Server, $Credential'
    'Get-ADUser'             = '$Identity, $Filter, $LDAPFilter, $SearchBase, $SearchScope, $Properties, $Server, $Credential'
    'Get-ADGroup'            = '$Identity, $Filter, $LDAPFilter, $SearchBase, $SearchScope, $Properties, $Server, $Credential'
    'Get-ADComputer'         = '$Identity, $Filter, $LDAPFilter, $SearchBase, $SearchScope, $Properties, $Server, $Credential'
    'New-ADUser'             = '$Name, $SamAccountName, $Path, $AccountPassword, $Enabled, $Server, $Credential, $PassThru'
    'Set-ADUser'             = '$Identity, $Replace, $Add, $Remove, $Clear, $Enabled, $Server, $Credential, $PassThru'
    'Get-ADTrust'            = '$Identity, $Filter, $Server, $Credential'
    'Get-ADRootDSE'          = '$Server, $Credential, $Properties'
    'Test-ADServiceAccount'  = '$Identity, $Server, $Credential'
}

foreach ($cmdletName in $adCmdletStubs.Keys) {
    if (Get-Command -Name $cmdletName -ErrorAction SilentlyContinue) {
        continue
    }

    # The parameter list is spliced into the function text so each stub carries its own names.
    # ValueFromRemainingArguments catches anything a call site passes that is not listed, so a
    # missing name degrades to an unmocked-call error rather than a binding error.
    $definition = @"
[CmdletBinding()]
param(
    $($adCmdletStubs[$cmdletName]),
    [Parameter(ValueFromRemainingArguments)]`$RemainingArguments
)
`$name = `$MyInvocation.MyCommand.Name
`$count = if (`$null -eq `$RemainingArguments) { 0 } else { @(`$RemainingArguments).Count }
throw "`$name stub: the ActiveDirectory module is not installed and this call (`$count unlisted argument(s)) was not mocked"
"@

    Set-Item -Path "function:global:$cmdletName" -Value ([scriptblock]::Create($definition))
}

# Test-OrphanedSID names this exception type in catch clauses. Without RSAT the type does not exist,
# and the first exception that reaches such a clause fails with "Unable to find type", which the
# outer catch then reports as the SID being orphaned. A stand-in with the same name keeps the
# clauses valid so the resolution order can be tested.
if (-not ('Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException' -as [type])) {
    Add-Type -TypeDefinition @'
namespace Microsoft.ActiveDirectory.Management
{
    public class ADIdentityNotFoundException : System.Exception
    {
        public ADIdentityNotFoundException() : base() { }
        public ADIdentityNotFoundException(string message) : base(message) { }
    }
}
'@
}

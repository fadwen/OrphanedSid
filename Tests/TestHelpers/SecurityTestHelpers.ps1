# Security test helpers: malicious input test cases, a pattern-based input checker, mock
# credentials and a mock AD environment. Dot-source from a test's BeforeAll.

function Get-MaliciousInputTestCases {
    [CmdletBinding()]
    param(
        [ValidateSet('All', 'CommandInjection', 'ScriptInjection', 'PathTraversal', 'SQLInjection')]
        [string]$Category = 'All'
    )
    
    $testCases = @{
        CommandInjection = @(
            @{ TestInput = 'OU=Test & net user hacker /add'; ShouldBlock = $true; Description = 'Command injection with net user' }
            @{ TestInput = 'OU=Test | powershell -Command "Remove-Item C:\*"'; ShouldBlock = $true; Description = 'PowerShell command injection' }
            @{ TestInput = 'OU=Test ; Start-Process calc.exe'; ShouldBlock = $true; Description = 'Process start injection' }
            @{ TestInput = 'OU=Test && echo malicious'; ShouldBlock = $true; Description = 'Command chaining injection' }
            @{ TestInput = 'OU=Test `$(Invoke-Expression "Get-Process")'; ShouldBlock = $true; Description = 'PowerShell subexpression injection' }
        )
        
        ScriptInjection = @(
            @{ TestInput = 'OU=Test"; Invoke-Expression "Remove-Item C:\*"'; ShouldBlock = $true; Description = 'Script block injection' }
            @{ TestInput = 'OU=Test`r`nInvoke-Command { Get-Process }'; ShouldBlock = $true; Description = 'Multi-line script injection' }
            @{ TestInput = 'OU=Test -EncodedCommand UwB0AGEAcgB0AC0AUAByAG8AYwBlAHMAcwAgAGMAYQBsAGMALgBlAHgAZQA='; ShouldBlock = $true; Description = 'Encoded command injection' }
        )
        
        PathTraversal = @(
            @{ TestInput = 'OU=Test\..\..\..\Windows\System32\config'; ShouldBlock = $true; Description = 'Windows path traversal' }
            @{ TestInput = 'OU=Test/../../../etc/passwd'; ShouldBlock = $true; Description = 'Unix path traversal' }
            @{ TestInput = 'OU=Test\..\..\..\..\secrets.txt'; ShouldBlock = $true; Description = 'Deep path traversal' }
            @{ TestInput = 'OU=Test%2e%2e%2fWindows%2fSystem32'; ShouldBlock = $true; Description = 'URL encoded path traversal' }
        )
        
        SQLInjection = @(
            @{ TestInput = "OU=Test'; DROP TABLE Users; --"; ShouldBlock = $true; Description = 'SQL injection with table drop' }
            @{ TestInput = "OU=Test' OR '1'='1"; ShouldBlock = $true; Description = 'SQL injection authentication bypass' }
            @{ TestInput = "OU=Test'; EXEC xp_cmdshell('net user hacker /add'); --"; ShouldBlock = $true; Description = 'SQL injection with command execution' }
        )
    }
    
    if ($Category -eq 'All') {
        $allCases = @()
        foreach ($cat in $testCases.Keys) {
            $allCases += $testCases[$cat]
        }
        return $allCases
    } else {
        return $testCases[$Category]
    }
}

function Test-InputForMaliciousContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputString,
        
        [ValidateSet('General', 'CommandInjection', 'ScriptInjection', 'PathTraversal', 'SQLInjection')]
        [string]$ValidationType = 'General'
    )
    
    $result = @{
        IsValid = $true
        RiskLevel = 'Low'
        Threats = @()
        InputString = $InputString
        ValidationType = $ValidationType
    }
    
    # Case-insensitive regex patterns per validation type
    $patterns = @{
        CommandInjection = @(
            '&.*net user',
            '\|.*powershell',
            ';.*start-process',
            '&.*cmd',
            '\$\(',
            '&&',
            '\|\|'
        )
        
        ScriptInjection = @(
            'invoke-expression',
            'invoke-command', 
            'start-process',
            'system\.diagnostics\.process',
            'encodedcommand',
            'iex '
        )
        
        PathTraversal = @(
            '\.\.',
            '%2e%2e',
            'windows\\system32',
            'etc/passwd',
            'config\\sam'
        )
        
        SQLInjection = @(
            "';.*drop",
            "'.*or.*'.*=",
            "xp_cmdshell",
            "';.*exec"
        )
        
        General = @(
            ' & ',
            ' \| ',
            ';',
            '\$\(',
            'invoke-',
            '\.\.',
            '%2e%2e',
            "';.*--",
            "' or '",
            ' && ',
            '-encodedcommand'
        )
    }
    
    # Test against patterns
    $testPatterns = if ($ValidationType -eq 'General') {
        $patterns['General']
    } else {
        $patterns[$ValidationType]
    }
    
    foreach ($pattern in $testPatterns) {
        Write-Verbose "Testing pattern '$pattern' against input '$InputString'"
        if ($InputString -imatch $pattern) {
            Write-Verbose "MATCH FOUND: Pattern '$pattern' matched in input"
            $result.IsValid = $false
            $result.RiskLevel = 'High'
            $result.Threats += @{
                Pattern = $pattern
                Match = $matches[0]
                Type = $ValidationType
            }
            break  # Exit on first match
        }
    }
    
    # Additional high-risk indicators
    $criticalPatterns = @(
        'format.*c:',
        'del.*c:',
        'remove-item.*c:',
        'system32',
        'etc/passwd',
        'drop.*table'
    )
    
    foreach ($pattern in $criticalPatterns) {
        if ($InputString -imatch $pattern) {
            $result.RiskLevel = 'Critical'
            break
        }
    }
    
    return $result
}

function New-SecureMockCredential {
    [CmdletBinding()]
    param(
        [string]$Username = 'testuser',
        [string]$Password = 'TestPassword123!'
    )
    
    $securePassword = ConvertTo-SecureString -String $Password -AsPlainText -Force
    return New-Object System.Management.Automation.PSCredential($Username, $securePassword)
}

function Write-SecurityTestLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [ValidateSet('Info', 'Warning', 'Error', 'Critical')]
        [string]$Level = 'Info',
        
        [string]$TestName = 'Unknown'
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry = "[$timestamp] [$Level] [$TestName] $Message"
    
    # Test log entries go to the verbose stream only
    Write-Verbose $logEntry
}

function Get-TestDataPath {
    [CmdletBinding()]
    param()
    
    $testRoot = Split-Path -Parent $PSScriptRoot
    return Join-Path $testRoot 'TestData'
}

function Test-ADSecurity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Operation,
        
        [hashtable]$Parameters = @{}
    )
    
    # Mock AD security validation
    $dangerousOperations = @(
        'Remove-ADObject',
        'Set-ADObject', 
        'Move-ADObject',
        'Remove-ADUser',
        'Remove-ADComputer'
    )
    
    if ($Operation -in $dangerousOperations) {
        Write-Warning "SECURITY: Dangerous AD operation '$Operation' detected and blocked in test environment"
        return @{
            Allowed = $false
            Reason = 'Dangerous operation blocked for security'
            Operation = $Operation
            Timestamp = Get-Date
        }
    }
    
    return @{
        Allowed = $true
        Operation = $Operation
        Timestamp = Get-Date
    }
}

function Get-MockADEnvironment {
    [CmdletBinding()]
    param()
    
    return @{
        Domain = @{
            Name = 'TESTDOMAIN'
            DNSRoot = 'testdomain.local'
            DistinguishedName = 'DC=testdomain,DC=local'
        }
        Users = @(
            @{ Name = 'TestUser1'; SID = 'S-1-5-21-1234567890-1234567890-1234567890-1001'; Status = 'Active' }
            @{ Name = 'TestUser2'; SID = 'S-1-5-21-1234567890-1234567890-1234567890-1002'; Status = 'Disabled' }
            @{ Name = 'OrphanedUser'; SID = 'S-1-5-21-9999999999-9999999999-9999999999-1001'; Status = 'Orphaned' }
        )
        Computers = @(
            @{ Name = 'TestPC1'; SID = 'S-1-5-21-1234567890-1234567890-1234567890-2001'; Status = 'Active' }
            @{ Name = 'TestPC2'; SID = 'S-1-5-21-1234567890-1234567890-1234567890-2002'; Status = 'Disabled' }
        )
    }
}

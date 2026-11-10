# Test-ValidDistinguishedName Tests

BeforeAll {
    $here = $PSScriptRoot

    $sut = (Split-Path -Leaf $PSCommandPath) -replace '\.Tests\.', '.'

    $functionPath = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $here)))) "Private\ActiveDirectory\Test-ValidDistinguishedName.ps1"

    if (Test-Path $functionPath) {
        . $functionPath
    }

    $basePath = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $here)))

    . (Join-Path $basePath "Private\Logging\Write-ADOperationSecurityLog.ps1")

    . (Join-Path $basePath "Private\Logging\Write-StructuredLog.ps1")
}

Describe "Test-ValidDistinguishedName" {
    
    BeforeEach {
        $env:PESTER_TESTING = $true

        $script:testData = @{
            ValidDNs = @(
                'CN=TestUser,OU=Users,DC=contoso,DC=com'
                'CN=Test Group,OU=Groups,OU=Security,DC=corp,DC=example,DC=org'
                'CN=Computer$,OU=Computers,DC=domain,DC=local'
                'OU=Organizational Unit,DC=test,DC=local'
                'CN=Certificate Templates,CN=Public Key Services,CN=Services,CN=Configuration,DC=contoso,DC=com'
                'CN=Users,DC=child,DC=parent,DC=com'
                'DC=contoso,DC=com'
                'CN=Jeff Stuhr,OU=IT Department,OU=Corporate,DC=techbyjeff,DC=net'
                'CN=Server-01$,OU=Domain Controllers,DC=contoso,DC=com'
                'CN=Exchange Organization,CN=Microsoft Exchange,CN=Services,CN=Configuration,DC=contoso,DC=com'
            )
            
            InvalidDNs = @(
                'InvalidDN'
                'CN=User'
                'OU=NoCommonName'
                'DC=onlydc'
                'CN=,OU=Users,DC=contoso,DC=com'  # Empty CN
                'CN=User,OU=,DC=contoso,DC=com'   # Empty OU
                'CN=User,DC=,DC=com'              # Empty DC
                'CN User OU=Users DC=contoso DC=com'  # Missing separators
                'CN==User,OU=Users,DC=contoso,DC=com'  # Double equals
                'RDN=User,OU=Users,DC=contoso,DC=com'  # Invalid RDN type
                ''  # Empty string
            )
            
            MaliciousDNs = @(
                'CN=User$(Get-Process),OU=Users,DC=contoso,DC=com'
                "CN=User`$(Invoke-Expression 'whoami'),OU=Users,DC=contoso,DC=com"
                'CN=User;DROP TABLE Users;--,OU=Users,DC=contoso,DC=com'
                'CN=User&powershell.exe,OU=Users,DC=contoso,DC=com'
                'CN=User|Out-File malicious.txt,OU=Users,DC=contoso,DC=com'
                "CN=User`nInvoke-Command,OU=Users,DC=contoso,DC=com"
                'CN=../../../etc/passwd,OU=Users,DC=contoso,DC=com'
                'CN=User<script>alert("xss")</script>,OU=Users,DC=contoso,DC=com'
                'CN=User%00,OU=Users,DC=contoso,DC=com'  # Null byte injection
                'CN=User' + [char]0x00 + 'Hidden,OU=Users,DC=contoso,DC=com'
            )
        }
        
        Mock Write-StructuredLog { }
        Mock Write-ADOperationSecurityLog { }
        Mock Write-Verbose { }
    }
    
    Context "Parameter Validation and Input Security" {
        It "Should handle empty string gracefully" {
            $result = '' | Test-ValidDistinguishedName
            $result | Should -Be $false
        }
        
        It "Should return one result per DN piped in" {
            $results = $script:testData.ValidDNs[0..2] | Test-ValidDistinguishedName

            $results | Should -Be @($true, $true, $true)
        }

        It "Should pass the given CorrelationId to the log" {
            $testCorrelationId = [System.Guid]::NewGuid().ToString()

            Test-ValidDistinguishedName -DistinguishedName $script:testData.ValidDNs[0] -CorrelationId $testCorrelationId

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $CorrelationId -eq $testCorrelationId }
        }

        It "Should auto-generate a GUID correlation ID when not provided" {
            Test-ValidDistinguishedName -DistinguishedName $script:testData.ValidDNs[0]

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $parsed = [System.Guid]::Empty
                [System.Guid]::TryParse($CorrelationId, [ref]$parsed)
            }
        }
        
        It "Should reject null input gracefully" {
            $result = Test-ValidDistinguishedName -DistinguishedName $null
            
            $result | Should -Be $false
        }
        
        It "Should reject empty string input" {
            $result = Test-ValidDistinguishedName -DistinguishedName ''
            
            $result | Should -Be $false
        }
    }
    
    Context "Basic DN Format Validation" {
        It "Should validate standard user DN format" {
            $userDN = 'CN=TestUser,OU=Users,DC=contoso,DC=com'
            
            $result = Test-ValidDistinguishedName -DistinguishedName $userDN
            
            $result | Should -Be $true
        }
        
        It "Should validate group DN format" {
            $groupDN = 'CN=Test Group,OU=Groups,OU=Security,DC=corp,DC=example,DC=org'
            
            $result = Test-ValidDistinguishedName -DistinguishedName $groupDN
            
            $result | Should -Be $true
        }
        
        It "Should validate computer DN format" {
            $computerDN = 'CN=Computer$,OU=Computers,DC=domain,DC=local'
            
            $result = Test-ValidDistinguishedName -DistinguishedName $computerDN
            
            $result | Should -Be $true
        }
        
        It "Should validate organizational unit DN format" {
            $ouDN = 'OU=Organizational Unit,DC=test,DC=local'
            
            $result = Test-ValidDistinguishedName -DistinguishedName $ouDN
            
            $result | Should -Be $true
        }
        
        It "Should validate domain component only DN" {
            $dcDN = 'DC=contoso,DC=com'
            
            $result = Test-ValidDistinguishedName -DistinguishedName $dcDN
            
            $result | Should -Be $true
        }
        
        It "Should validate complex configuration container DN" {
            $configDN = 'CN=Certificate Templates,CN=Public Key Services,CN=Services,CN=Configuration,DC=contoso,DC=com'
            
            $result = Test-ValidDistinguishedName -DistinguishedName $configDN
            
            $result | Should -Be $true
        }
    }
    
    Context "Invalid DN Format Detection" {
        It "Should reject obviously invalid DN - InvalidDN" {
            $result = Test-ValidDistinguishedName -DistinguishedName 'InvalidDN'
            $result | Should -Be $false
        }
        
        It "Should reject obviously invalid DN - CN=User" {
            $result = Test-ValidDistinguishedName -DistinguishedName 'CN=User'
            $result | Should -Be $false
        }
        
        It "Should reject obviously invalid DN - OU=NoCommonName" {
            $result = Test-ValidDistinguishedName -DistinguishedName 'OU=NoCommonName'
            $result | Should -Be $false
        }
        
        It "Should reject obviously invalid DN - DC=onlydc" {
            $result = Test-ValidDistinguishedName -DistinguishedName 'DC=onlydc'
            $result | Should -Be $false
        }
        
        It "Should reject DNs with empty components" {
            $emptyComponentDNs = @(
                'CN=,OU=Users,DC=contoso,DC=com'
                'CN=User,OU=,DC=contoso,DC=com'
                'CN=User,DC=,DC=com'
            )
            
            foreach ($dn in $emptyComponentDNs) {
                $result = Test-ValidDistinguishedName -DistinguishedName $dn
                $result | Should -Be $false
            }
        }
        
        It "Should reject DNs with invalid separators" {
            $invalidSeparatorDNs = @(
                'CN User OU=Users DC=contoso DC=com'
                'CN==User,OU=Users,DC=contoso,DC=com'
                'RDN=User,OU=Users,DC=contoso,DC=com'
            )
            
            foreach ($dn in $invalidSeparatorDNs) {
                $result = Test-ValidDistinguishedName -DistinguishedName $dn
                $result | Should -Be $false
            }
        }
    }
    
    Context "Security Injection Prevention" {
        # Each DN is otherwise well formed, so the rejection must come from the injection pattern
        # named in the warning, not from the format checks.
        It "Should reject <Case> with a dangerous-pattern warning" -ForEach @(
            @{ Case = 'a PowerShell subexpression'; DN = 'CN=User$(Get-Process),OU=Users,DC=contoso,DC=com'; Pattern = '\$\(' }
            @{ Case = 'a backtick-escaped variable'; DN = 'CN=User`$x,OU=Users,DC=contoso,DC=com'; Pattern = '`\$' }
            @{ Case = 'a command separator'; DN = 'CN=User&powershell.exe,OU=Users,DC=contoso,DC=com'; Pattern = '&' }
            @{ Case = 'a pipe'; DN = 'CN=User|Out-File malicious.txt,OU=Users,DC=contoso,DC=com'; Pattern = '\|' }
            @{ Case = 'SQL injection'; DN = 'CN=User;DROP TABLE Users;--,OU=Users,DC=contoso,DC=com'; Pattern = ';' }
            @{ Case = 'path traversal'; DN = 'CN=../../../etc/passwd,OU=Users,DC=contoso,DC=com'; Pattern = '\.\.\/' }
            @{ Case = 'script injection'; DN = 'CN=User<script>alert(1),OU=Users,DC=contoso,DC=com'; Pattern = '<script' }
            @{ Case = 'URL-encoded null byte'; DN = 'CN=User%00,OU=Users,DC=contoso,DC=com'; Pattern = '%[0-9A-Fa-f]' }
            @{ Case = 'an embedded null character'; DN = ('CN=User' + [char]0x00 + 'Hidden,OU=Users,DC=contoso,DC=com'); Pattern = '\x00' }
            @{ Case = 'a SQL comment'; DN = 'CN=User--x,OU=Users,DC=contoso,DC=com'; Pattern = '--' }
        ) {
            $result = Test-ValidDistinguishedName -DistinguishedName $DN

            $result | Should -Be $false
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq "Distinguished Name validation failed: Contains dangerous characters: $Pattern" -and
                $Level -eq 'Warning'
            }
        }

        It "Should reject control characters with a control-character warning" {
            # A bell character; a newline would already fail the single-line format check
            $controlCharDN = 'CN=User' + [char]0x07 + 'Bell,OU=Users,DC=contoso,DC=com'

            $result = Test-ValidDistinguishedName -DistinguishedName $controlCharDN

            $result | Should -Be $false
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'Distinguished Name validation failed: Contains control characters' -and $Level -eq 'Warning'
            }
        }
    }
    
    Context "LDAP Compliance and RFC Standards" {
        It "Should handle Unicode characters properly" {
            $unicodeDN = 'CN=Üser Tëst,OU=Spëcial Ćhars,DC=tëst,DC=cöm'
            
            $result = Test-ValidDistinguishedName -DistinguishedName $unicodeDN
            
            $result | Should -Be $true
        }
        
        It "Should handle escaped characters correctly" {
            $escapedDN = 'CN=User\, Name,OU=Users\=Test,DC=contoso,DC=com'
            
            $result = Test-ValidDistinguishedName -DistinguishedName $escapedDN
            
            $result | Should -Be $true
        }
        
        It "Should handle quoted values correctly" {
            $quotedDN = 'CN="User, With Comma",OU=Users,DC=contoso,DC=com'
            
            $result = Test-ValidDistinguishedName -DistinguishedName $quotedDN
            
            $result | Should -Be $true
        }
        
        It "Should -be case insensitive for attribute names" {
            $mixedCaseDN = 'cn=user,ou=users,dc=CONTOSO,DC=COM'
            
            $result = Test-ValidDistinguishedName -DistinguishedName $mixedCaseDN
            
            $result | Should -Be $true
        }
        
        It "Should handle spaces around equals signs" {
            $spacedDN = 'CN = User Name , OU = Users , DC = contoso , DC = com'
            
            $result = Test-ValidDistinguishedName -DistinguishedName $spacedDN
            
            # Should normalize spaces correctly
            $result | Should -Be $true
        }
        
        It "Should validate against maximum DN length limits" {
            # Well formed, but longer than the DN length limit
            $longDN = 'CN=' + ('A' * 500) + ',OU=' + ('B' * 500) + ',DC=' + ('C' * 500) + ',DC=com'
            
            $result = Test-ValidDistinguishedName -DistinguishedName $longDN
            
            # Should reject overly long DNs
            $result | Should -Be $false
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq "Distinguished Name validation failed: Length exceeds 1024 characters ($($longDN.Length))"
            }
        }

        It "Should accept a DN of exactly 1024 characters" {
            $prefix = 'CN='
            $suffix = ',OU=Users,DC=contoso,DC=com'
            $boundaryDN = $prefix + ('A' * (1024 - $prefix.Length - $suffix.Length)) + $suffix
            $boundaryDN.Length | Should -Be 1024

            Test-ValidDistinguishedName -DistinguishedName $boundaryDN | Should -Be $true
        }

        It "Should reject a DN whose only DC= follows an escaped comma" {
            # The format check sees ',DC=' but the escaped comma keeps it inside the CN component
            $result = Test-ValidDistinguishedName -DistinguishedName 'CN=User\,DC=contoso'

            $result | Should -Be $false
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'Distinguished Name validation failed: No domain components (DC=) found'
            }
        }

        It "Should reject a component whose quoted value is empty" {
            $result = Test-ValidDistinguishedName -DistinguishedName 'CN="",OU=Users,DC=contoso,DC=com'

            $result | Should -Be $false
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'Distinguished Name validation failed: Empty component value: CN=""'
            }
        }
    }
    
    Context "Batch Processing and Array Handling" {
        It "Should process multiple valid DNs correctly" {
            $validDNs = $script:testData.ValidDNs[0..4]
            
            $results = $validDNs | Test-ValidDistinguishedName
            
            @($results).Count | Should -Be $validDNs.Count
            $results | Where-Object { $_ -eq $false } | Should -BeNullOrEmpty
        }
        
        It "Should process mixed valid and invalid DNs" {
            $mixedDNs = @(
                $script:testData.ValidDNs[0]
                $script:testData.InvalidDNs[0]
                $script:testData.ValidDNs[1]
                $script:testData.InvalidDNs[1]
            )
            
            $results = $mixedDNs | Test-ValidDistinguishedName
            
            @($results).Count | Should -Be 4
            $results[0] | Should -Be $true   # Valid
            $results[1] | Should -Be $false  # Invalid
            $results[2] | Should -Be $true   # Valid
            $results[3] | Should -Be $false  # Invalid
        }
        
        It "Should handle empty array input" {
            $results = @() | Test-ValidDistinguishedName
            
            $results | Should -BeNullOrEmpty
        }
        
        It "Should handle large arrays efficiently" {
            # Create large array of valid DNs
            $largeDNArray = 1..100 | ForEach-Object {
                "CN=User$_,OU=Users,DC=contoso,DC=com"
            }
            
            $results = $largeDNArray | Test-ValidDistinguishedName
            
            @($results).Count | Should -Be 100
            $results | Where-Object { $_ -eq $false } | Should -BeNullOrEmpty
        }
    }
    
    Context "Enterprise Security Logging and Auditing" {
        It "Should log a Debug success entry with the DN and correlation ID" {
            $testDN = 'CN=TestUser,OU=Users,DC=contoso,DC=com'
            $testCorrelationId = [System.Guid]::NewGuid().ToString()

            Test-ValidDistinguishedName -DistinguishedName $testDN -CorrelationId $testCorrelationId

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq "Distinguished Name validation successful: $testDN" -and
                $Level -eq 'Debug' -and
                $Component -eq 'DNValidator' -and
                $CorrelationId -eq $testCorrelationId
            }
        }

        It "Should log exactly one entry per DN validated" {
            $mixedDNs = @(
                $script:testData.ValidDNs[0]
                $script:testData.InvalidDNs[0]
                $script:testData.MaliciousDNs[0]
            )
            $testCorrelationId = [System.Guid]::NewGuid().ToString()

            $mixedDNs | Test-ValidDistinguishedName -CorrelationId $testCorrelationId

            Should -Invoke Write-StructuredLog -Times 3 -Exactly
            Should -Invoke Write-StructuredLog -Times 3 -Exactly -ParameterFilter {
                $Component -eq 'DNValidator' -and $CorrelationId -eq $testCorrelationId
            }
        }

        It "Should log a format failure at Debug, not Warning" {
            Test-ValidDistinguishedName -DistinguishedName 'InvalidDN'

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -eq 'Distinguished Name validation failed: Invalid format structure' -and
                $Level -eq 'Debug'
            }
        }

        It "Should log one success entry per valid DN in a batch" {
            $testDNs = $script:testData.ValidDNs[0..2]

            $testDNs | Test-ValidDistinguishedName

            foreach ($dn in $testDNs) {
                Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                    $Message -eq "Distinguished Name validation successful: $dn"
                }
            }
        }
    }
    
    Context "Error Handling and Edge Cases" {
        It "Should handle null values in arrays gracefully" {
            $arrayWithNulls = @(
                'CN=ValidUser,OU=Users,DC=contoso,DC=com'
                $null
                'CN=AnotherValidUser,OU=Users,DC=contoso,DC=com'
            )
            
            $results = $arrayWithNulls | Test-ValidDistinguishedName
            
            @($results).Count | Should -Be 3
            $results[0] | Should -Be $true
            $results[1] | Should -Be $false  # null Should -be invalid
            $results[2] | Should -Be $true
        }
        
        It "Should handle whitespace-only strings" {
            $whitespaceStrings = @(
                '   '
                "`t"
                "`n"
                "`r`n"
            )
            
            foreach ($ws in $whitespaceStrings) {
                $result = Test-ValidDistinguishedName -DistinguishedName $ws
                $result | Should -Be $false
            }
        }
        
        It "Should handle extremely long individual DN components" {
            $longComponentDN = 'CN=' + ('A' * 1000) + ',OU=Users,DC=contoso,DC=com'
            
            $result = Test-ValidDistinguishedName -DistinguishedName $longComponentDN
            
            # The DN as a whole is then over the 1024-character limit
            $result | Should -Be $false
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Message -like 'Distinguished Name validation failed: Length exceeds 1024 characters*'
            }
        }

        It "Should accept regex metacharacters in a value as ordinary characters" {
            $specialCharDNs = @(
                'CN=User[],OU=Users,DC=contoso,DC=com'
                'CN=User(),OU=Users,DC=contoso,DC=com'
                'CN=User{},OU=Users,DC=contoso,DC=com'
                'CN=User^,OU=Users,DC=contoso,DC=com'
            )

            $results = $specialCharDNs | Test-ValidDistinguishedName

            $results | Should -Be @($true, $true, $true, $true)
            Should -Invoke Write-StructuredLog -Times 0 -Exactly -ParameterFilter {
                $Message -like 'Distinguished Name validation error:*'
            }
        }
    }
    
    AfterEach {
        # Clean up test environment
        Remove-Variable -Name 'testData' -Scope Script -ErrorAction SilentlyContinue
        $env:PESTER_TESTING = $null
    }
}

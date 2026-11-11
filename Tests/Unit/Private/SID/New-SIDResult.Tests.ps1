# New-SIDResult.Tests.ps1
# Tests for Private/SID/New-SIDResult.ps1 (New-OrphanedSIDResult and related functions)

# Stubs Write-StructuredLog and Test-SIDFormat, then loads the classes and the Private/SID functions
BeforeAll {
    function Write-StructuredLog { param($Message, $Level, $CorrelationId, $Component, $Data) }

    function Test-SIDFormat { param($SID) return $SID -match '^S-1-\d+' }

    $ClassPath = Join-Path $PSScriptRoot '..\..\..\..\Classes'

    if (Test-Path $ClassPath) {
        Get-ChildItem -Path $ClassPath -Filter '*.ps1' | ForEach-Object { . $_.FullName }
    }

    $SIDPath = Join-Path $PSScriptRoot '..\..\..\..\Private\SID'

    if (Test-Path $SIDPath) {
        Get-ChildItem -Path $SIDPath -Filter '*.ps1' | ForEach-Object { . $_.FullName }
    }

    Mock Write-StructuredLog { }
}

Describe "New-OrphanedSIDResult Function Tests" {
    
    Context "Function Existence and Core Functionality" {
        It "Should return OrphanedSIDResult object" {
            $testObjectDN = 'CN=TestUser,OU=Users,DC=contoso,DC=com'
            $testSID = 'S-1-5-21-1234567890-1234567890-1234567890-1001'
            $testAccessRule = [PSCustomObject]@{
                AccessControlType = 'Allow'
                ActiveDirectoryRights = 'ReadProperty'
            }
            
            $result = New-OrphanedSIDResult -ObjectDN $testObjectDN -OrphanedSID $testSID -AccessRule $testAccessRule
            $result | Should -Not -BeNullOrEmpty
            $result.GetType().Name | Should -Be 'OrphanedSIDResult'
        }
        
        It "Should include correlation ID tracking" {
            $testObjectDN = 'CN=TestUser,OU=Users,DC=contoso,DC=com'
            $testSID = 'S-1-5-21-1234567890-1234567890-1234567890-1001'
            $testAccessRule = [PSCustomObject]@{ AccessControlType = 'Allow'; ActiveDirectoryRights = 'ReadProperty' }
            $correlationId = [System.Guid]::NewGuid().ToString()
            
            $result = New-OrphanedSIDResult -ObjectDN $testObjectDN -OrphanedSID $testSID -AccessRule $testAccessRule -CorrelationId $correlationId
            $result.CorrelationId | Should -Be $correlationId
        }

        It "Should mark a result Orphaned by default" {
            $testAccessRule = [PSCustomObject]@{ AccessControlType = 'Allow'; ActiveDirectoryRights = 'ReadProperty' }

            $result = New-OrphanedSIDResult -ObjectDN 'CN=TestUser,OU=Users,DC=contoso,DC=com' -OrphanedSID 'S-1-5-21-1234567890-1234567890-1234567890-1001' -AccessRule $testAccessRule

            $result.VerificationStatus | Should -Be 'Orphaned'
            $result.VerificationError | Should -BeNullOrEmpty
        }

        It "Should carry an Unverified status and the lookup failure" {
            $testAccessRule = [PSCustomObject]@{ AccessControlType = 'Allow'; ActiveDirectoryRights = 'ReadProperty' }
            $params = @{
                ObjectDN           = 'CN=TestUser,OU=Users,DC=contoso,DC=com'
                OrphanedSID        = 'S-1-5-21-1234567890-1234567890-1234567890-1001'
                AccessRule         = $testAccessRule
                VerificationStatus = 'Unverified'
                VerificationError  = 'Get-ADObject: Access is denied'
            }

            $result = New-OrphanedSIDResult @params

            $result.VerificationStatus | Should -Be 'Unverified'
            $result.VerificationError | Should -Be 'Get-ADObject: Access is denied'
        }

        It "Should reject a verification status other than Orphaned or Unverified" {
            $testAccessRule = [PSCustomObject]@{ AccessControlType = 'Allow'; ActiveDirectoryRights = 'ReadProperty' }

            { New-OrphanedSIDResult -ObjectDN 'CN=TestUser,DC=contoso,DC=com' -OrphanedSID 'S-1-5-21-1-2-3-1001' -AccessRule $testAccessRule -VerificationStatus 'Exists' } | Should -Throw
        }
    }
    
    Context "Parameter Validation and Error Handling" {
        It "Should validate required ObjectDN parameter" {
            $testSID = 'S-1-5-21-1234567890-1234567890-1234567890-1001'
            $testAccessRule = [PSCustomObject]@{ AccessControlType = 'Allow' }
            
            { New-OrphanedSIDResult -ObjectDN $null -OrphanedSID $testSID -AccessRule $testAccessRule } | Should -Throw
        }
        
        It "Should validate required OrphanedSID parameter" {
            $testObjectDN = 'CN=TestUser,OU=Users,DC=contoso,DC=com'
            $testAccessRule = [PSCustomObject]@{ AccessControlType = 'Allow' }
            
            { New-OrphanedSIDResult -ObjectDN $testObjectDN -OrphanedSID $null -AccessRule $testAccessRule } | Should -Throw
        }
        
        It "Should validate SID format through Test-SIDFormat function" {
            $testObjectDN = 'CN=TestUser,OU=Users,DC=contoso,DC=com'
            $invalidSID = 'INVALID-SID-FORMAT'
            $testAccessRule = [PSCustomObject]@{ AccessControlType = 'Allow' }

            { New-OrphanedSIDResult -ObjectDN $testObjectDN -OrphanedSID $invalidSID -AccessRule $testAccessRule -CorrelationId 'res-err' } |
                Should -Throw -ExpectedMessage 'Failed to create OrphanedSIDResult: Invalid SID format provided: INVALID-SID-FORMAT'
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Error' -and $CorrelationId -eq 'res-err' -and $Message -like "Error creating OrphanedSIDResult object for $testObjectDN*"
            }
        }
        
        It "Should validate Confidence parameter values" {
            $testObjectDN = 'CN=TestUser,OU=Users,DC=contoso,DC=com'
            $testSID = 'S-1-5-21-1234567890-1234567890-1234567890-1001'
            $testAccessRule = [PSCustomObject]@{ AccessControlType = 'Allow' }
            
            { New-OrphanedSIDResult -ObjectDN $testObjectDN -OrphanedSID $testSID -AccessRule $testAccessRule -Confidence 'InvalidLevel' } | Should -Throw
        }
        
        It "Should accept valid Confidence parameter values" {
            $testObjectDN = 'CN=TestUser,OU=Users,DC=contoso,DC=com'
            $testSID = 'S-1-5-21-1234567890-1234567890-1234567890-1001'
            $testAccessRule = [PSCustomObject]@{ AccessControlType = 'Allow' }
            
            foreach ($level in 'High', 'Medium', 'Low') {
                (New-OrphanedSIDResult -ObjectDN $testObjectDN -OrphanedSID $testSID -AccessRule $testAccessRule -Confidence $level).Confidence |
                    Should -Be $level
            }
        }
    }
    
    Context "Result Object Properties and Metadata" {
        It "Should populate core object identification properties" {
            $testObjectDN = 'CN=TestUser,OU=Users,DC=contoso,DC=com'
            $testObjectClass = 'User'
            $testSID = 'S-1-5-21-1234567890-1234567890-1234567890-1001'
            $testAccessRule = [PSCustomObject]@{ AccessControlType = 'Allow'; ActiveDirectoryRights = 'ReadProperty' }
            $likelySource = 'Deleted User'
            $confidence = 'High'
            $notes = 'Test analysis notes'
            
            $result = New-OrphanedSIDResult -ObjectDN $testObjectDN -ObjectClass $testObjectClass -OrphanedSID $testSID -AccessRule $testAccessRule -LikelySource $likelySource -Confidence $confidence -Notes $notes
            
            $result.ObjectDN | Should -Be $testObjectDN
            $result.ObjectClass | Should -Be $testObjectClass
            $result.OrphanedSID | Should -Be $testSID
            $result.LikelySource | Should -Be $likelySource
            $result.Confidence | Should -Be $confidence
            $result.AnalysisNotes | Should -Be $notes
        }
        
        It "Should include processing metadata" {
            $testObjectDN = 'CN=TestUser,OU=Users,DC=contoso,DC=com'
            $testSID = 'S-1-5-21-1234567890-1234567890-1234567890-1001'
            $testAccessRule = [PSCustomObject]@{ AccessControlType = 'Allow' }
            $processingMethod = 'Enhanced-ACL-Retrieval'
            
            $result = New-OrphanedSIDResult -ObjectDN $testObjectDN -OrphanedSID $testSID -AccessRule $testAccessRule -ProcessingMethod $processingMethod
            
            $result.ProcessingMethod | Should -Be $processingMethod
            $result.ActionTaken | Should -Be 'Detected'
            $result.Timestamp | Should -Not -BeNullOrEmpty
            $result.ProcessingContext | Should -Not -BeNullOrEmpty
        }
        
        It "Should extract ACL metadata from access rule" {
            $testObjectDN = 'CN=TestUser,OU=Users,DC=contoso,DC=com'
            $testSID = 'S-1-5-21-1234567890-1234567890-1234567890-1001'
            $testAccessRule = [PSCustomObject]@{
                AccessControlType = 'Allow'
                ActiveDirectoryRights = 'ReadProperty, WriteProperty'
                InheritanceFlags = 'ContainerInherit'
                IsInherited = $true
                ObjectType = [System.Guid]::NewGuid()
                InheritedObjectType = [System.Guid]::NewGuid()
            }
            
            $result = New-OrphanedSIDResult -ObjectDN $testObjectDN -OrphanedSID $testSID -AccessRule $testAccessRule
            
            $result.AccessControlType | Should -Be $testAccessRule.AccessControlType
            $result.ActiveDirectoryRights | Should -Be $testAccessRule.ActiveDirectoryRights
            $result.InheritanceType | Should -Be $testAccessRule.InheritanceFlags
            $result.IsInherited | Should -Be $testAccessRule.IsInherited
            $result.ObjectType | Should -Be $testAccessRule.ObjectType
            $result.InheritedObjectType | Should -Be $testAccessRule.InheritedObjectType
        }
        
        It "Should handle default values for optional parameters" {
            $testObjectDN = 'CN=TestUser,OU=Users,DC=contoso,DC=com'
            $testSID = 'S-1-5-21-1234567890-1234567890-1234567890-1001'
            $testAccessRule = [PSCustomObject]@{ AccessControlType = 'Allow' }
            
            $result = New-OrphanedSIDResult -ObjectDN $testObjectDN -OrphanedSID $testSID -AccessRule $testAccessRule
            
            $result.ObjectClass | Should -Be 'Unknown'
            $result.LikelySource | Should -Be 'Unknown'
            $result.Confidence | Should -Be 'Medium'
            $result.AnalysisNotes | Should -Be ''
            $result.ProcessingMethod | Should -Be 'Standard'
        }
    }
    
    Context "ACL Metadata Extraction with Missing Properties" {
        It "Should handle access rule with missing AccessControlType" {
            $testObjectDN = 'CN=TestUser,OU=Users,DC=contoso,DC=com'
            $testSID = 'S-1-5-21-1234567890-1234567890-1234567890-1001'
            $testAccessRule = [PSCustomObject]@{
                ActiveDirectoryRights = 'ReadProperty'
                # AccessControlType missing
            }
            
            $result = New-OrphanedSIDResult -ObjectDN $testObjectDN -OrphanedSID $testSID -AccessRule $testAccessRule
            $result.AccessControlType | Should -Be 'Allow'
        }
        
        It "Should handle access rule with missing ActiveDirectoryRights" {
            $testObjectDN = 'CN=TestUser,OU=Users,DC=contoso,DC=com'
            $testSID = 'S-1-5-21-1234567890-1234567890-1234567890-1001'
            $testAccessRule = [PSCustomObject]@{
                AccessControlType = 'Allow'
                # ActiveDirectoryRights missing
            }
            
            $result = New-OrphanedSIDResult -ObjectDN $testObjectDN -OrphanedSID $testSID -AccessRule $testAccessRule
            $result.ActiveDirectoryRights | Should -Be 'GenericRead'
        }
        
        It "Should handle access rule with Rights property instead of ActiveDirectoryRights" {
            $testObjectDN = 'CN=TestUser,OU=Users,DC=contoso,DC=com'
            $testSID = 'S-1-5-21-1234567890-1234567890-1234567890-1001'
            $testAccessRule = [PSCustomObject]@{
                AccessControlType = 'Allow'
                Rights = 'GenericAll'  # Alternative property name
            }
            
            $result = New-OrphanedSIDResult -ObjectDN $testObjectDN -OrphanedSID $testSID -AccessRule $testAccessRule
            $result.ActiveDirectoryRights | Should -Be 'GenericAll'
        }
        
        It "Should handle access rule with missing inheritance properties" {
            $testObjectDN = 'CN=TestUser,OU=Users,DC=contoso,DC=com'
            $testSID = 'S-1-5-21-1234567890-1234567890-1234567890-1001'
            $testAccessRule = [PSCustomObject]@{
                AccessControlType = 'Allow'
                ActiveDirectoryRights = 'ReadProperty'
                # InheritanceFlags and IsInherited missing
            }
            
            $result = New-OrphanedSIDResult -ObjectDN $testObjectDN -OrphanedSID $testSID -AccessRule $testAccessRule
            $result.InheritanceType | Should -Be 'None'
            $result.IsInherited | Should -Be $false
        }
    }
    
    Context "GUID Property Handling" {
        It "Should handle valid GUID objects" {
            $testObjectDN = 'CN=TestUser,OU=Users,DC=contoso,DC=com'
            $testSID = 'S-1-5-21-1234567890-1234567890-1234567890-1001'
            $testGuid = [System.Guid]::NewGuid()
            $testAccessRule = [PSCustomObject]@{
                AccessControlType = 'Allow'
                ObjectType = $testGuid
                InheritedObjectType = $testGuid
            }
            
            $result = New-OrphanedSIDResult -ObjectDN $testObjectDN -OrphanedSID $testSID -AccessRule $testAccessRule
            $result.ObjectType | Should -Be $testGuid
            $result.InheritedObjectType | Should -Be $testGuid
        }
        
        It "Should handle empty GUID objects" {
            $testObjectDN = 'CN=TestUser,OU=Users,DC=contoso,DC=com'
            $testSID = 'S-1-5-21-1234567890-1234567890-1234567890-1001'
            $testAccessRule = [PSCustomObject]@{
                AccessControlType = 'Allow'
                ObjectType = [System.Guid]::Empty
                InheritedObjectType = [System.Guid]::Empty
            }
            
            $result = New-OrphanedSIDResult -ObjectDN $testObjectDN -OrphanedSID $testSID -AccessRule $testAccessRule
            $result.ObjectType | Should -Be ([System.Guid]::Empty)
            $result.InheritedObjectType | Should -Be ([System.Guid]::Empty)
        }
        
        It "Should handle GUID strings" {
            $testObjectDN = 'CN=TestUser,OU=Users,DC=contoso,DC=com'
            $testSID = 'S-1-5-21-1234567890-1234567890-1234567890-1001'
            $testGuidString = '12345678-1234-5678-9abc-123456789012'
            $testAccessRule = [PSCustomObject]@{
                AccessControlType = 'Allow'
                ObjectType = $testGuidString
                InheritedObjectType = $testGuidString
            }
            
            $result = New-OrphanedSIDResult -ObjectDN $testObjectDN -OrphanedSID $testSID -AccessRule $testAccessRule
            $result.ObjectType | Should -Be ([System.Guid]::Parse($testGuidString))
        }
        
        It "Should handle null or empty GUID properties" {
            $testObjectDN = 'CN=TestUser,OU=Users,DC=contoso,DC=com'
            $testSID = 'S-1-5-21-1234567890-1234567890-1234567890-1001'
            $testAccessRule = [PSCustomObject]@{
                AccessControlType = 'Allow'
                ObjectType = $null
                InheritedObjectType = ''
            }
            
            $result = New-OrphanedSIDResult -ObjectDN $testObjectDN -OrphanedSID $testSID -AccessRule $testAccessRule
            $result.ObjectType | Should -Be ([System.Guid]::Empty)
            $result.InheritedObjectType | Should -Be ([System.Guid]::Empty)
        }

        It "Should use an empty GUID for a string that is not a GUID" {
            $testAccessRule = [PSCustomObject]@{ AccessControlType = 'Allow'; ObjectType = 'not-a-guid' }

            $result = New-OrphanedSIDResult -ObjectDN 'CN=TestUser,DC=contoso,DC=com' -OrphanedSID 'S-1-5-21-1234567890-1234567890-1234567890-1001' -AccessRule $testAccessRule

            $result.ObjectType | Should -Be ([System.Guid]::Empty)
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -eq 'Failed to parse GUID string for ObjectType : not-a-guid' }
        }

        It "Should use an empty GUID for a value of an unexpected type" {
            $testAccessRule = [PSCustomObject]@{ AccessControlType = 'Allow'; ObjectType = 42 }

            $result = New-OrphanedSIDResult -ObjectDN 'CN=TestUser,DC=contoso,DC=com' -OrphanedSID 'S-1-5-21-1234567890-1234567890-1234567890-1001' -AccessRule $testAccessRule

            $result.ObjectType | Should -Be ([System.Guid]::Empty)
            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter { $Message -eq 'GUID property ObjectType has unexpected type: Int32' }
        }
    }
    
    Context "Processing Context and Enterprise Features" {
        It "Should include comprehensive processing context" {
            $testObjectDN = 'CN=TestUser,OU=Users,DC=contoso,DC=com'
            $testSID = 'S-1-5-21-1234567890-1234567890-1234567890-1001'
            $testAccessRule = [PSCustomObject]@{ AccessControlType = 'Allow' }
            
            $result = New-OrphanedSIDResult -ObjectDN $testObjectDN -OrphanedSID $testSID -AccessRule $testAccessRule
            
            $result.ProcessingContext | Should -Not -BeNullOrEmpty
            $result.ProcessingContext.MachineName | Should -Be $env:COMPUTERNAME
            $result.ProcessingContext.UserName | Should -Be $env:USERNAME
            $result.ProcessingContext.ProcessId | Should -Be $PID
            $result.ProcessingContext.PowerShellVersion | Should -Not -BeNullOrEmpty
            $result.ProcessingContext.ModuleVersion | Should -Be '1.0.0'
        }
        
        It "Should trim ObjectDN input" {
            $testObjectDN = '  CN=TestUser,OU=Users,DC=contoso,DC=com  '
            $testSID = 'S-1-5-21-1234567890-1234567890-1234567890-1001'
            $testAccessRule = [PSCustomObject]@{ AccessControlType = 'Allow' }
            
            $result = New-OrphanedSIDResult -ObjectDN $testObjectDN -OrphanedSID $testSID -AccessRule $testAccessRule
            $result.ObjectDN | Should -Be 'CN=TestUser,OU=Users,DC=contoso,DC=com'
        }
        
        It "Should auto-generate correlation ID when not provided" {
            $testObjectDN = 'CN=TestUser,OU=Users,DC=contoso,DC=com'
            $testSID = 'S-1-5-21-1234567890-1234567890-1234567890-1001'
            $testAccessRule = [PSCustomObject]@{ AccessControlType = 'Allow' }
            
            $result = New-OrphanedSIDResult -ObjectDN $testObjectDN -OrphanedSID $testSID -AccessRule $testAccessRule
            $result.CorrelationId | Should -Not -BeNullOrEmpty
            # Should -be a valid GUID format
            { [System.Guid]::Parse($result.CorrelationId) } | Should -Not -Throw
        }
    }
}

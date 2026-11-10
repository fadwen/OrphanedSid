#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
BeforeAll {
    $ModuleRoot = Resolve-Path "$PSScriptRoot\..\..\.."

    . "$ModuleRoot\Classes\OrphanedSIDResult.ps1"
}

Describe "OrphanedSIDResult Class Tests" -Tag "Unit", "Classes", "OrphanedSIDResult" {

    Context "Constructor Tests" {
        It "Should create instance with a GUID correlation ID" {
            $result = [OrphanedSIDResult]::new()

            $result.CorrelationId | Should -Match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
        }

        It "Should default VerificationStatus to Orphaned with no VerificationError" {
            $result = [OrphanedSIDResult]::new()

            $result.VerificationStatus | Should -Be 'Orphaned'
            $result.VerificationError | Should -BeNullOrEmpty
        }

        It "Should set Timestamp to the time of construction" {
            $beforeCreate = Get-Date
            $result = [OrphanedSIDResult]::new()
            $afterCreate = Get-Date

            $result.Timestamp | Should -BeGreaterOrEqual $beforeCreate
            $result.Timestamp | Should -BeLessOrEqual $afterCreate
        }

        It "Should generate unique CorrelationId for each instance" {
            $result1 = [OrphanedSIDResult]::new()
            $result2 = [OrphanedSIDResult]::new()

            $result1.CorrelationId | Should -Not -Be $result2.CorrelationId
        }
    }

    Context "Property Tests" {
        BeforeEach {
            $script:testResult = [OrphanedSIDResult]::new()
        }

        It "Should declare the property types consumers rely on" {
            # String properties are null until set, so set them to test their declared type
            foreach ($name in 'ObjectDN', 'ObjectClass', 'OrphanedSID', 'LikelySource', 'Confidence',
                'AnalysisNotes', 'ProcessingMethod', 'ActionTaken', 'VerificationError') {
                $script:testResult.$name = 'Test'
                $script:testResult.$name | Should -BeOfType [string]
            }

            $script:testResult.AccessControlType | Should -BeOfType [System.Security.AccessControl.AccessControlType]
            $script:testResult.ActiveDirectoryRights | Should -BeOfType [System.DirectoryServices.ActiveDirectoryRights]
            $script:testResult.InheritanceType | Should -BeOfType [System.Security.AccessControl.InheritanceFlags]
            $script:testResult.ObjectType | Should -BeOfType [System.Guid]
            $script:testResult.InheritedObjectType | Should -BeOfType [System.Guid]
            $script:testResult.IsInherited | Should -BeOfType [bool]
            $script:testResult.VerificationStatus | Should -BeOfType [string]
            $script:testResult.CorrelationId | Should -BeOfType [string]
            $script:testResult.Timestamp | Should -BeOfType [DateTime]
        }
    }

    Context "Property Default Values" {
        BeforeEach {
            $script:testResult = [OrphanedSIDResult]::new()
        }

        It "Should have null or empty default values for string properties" {
            $script:testResult.ObjectDN | Should -BeNullOrEmpty
            $script:testResult.ObjectClass | Should -BeNullOrEmpty
            $script:testResult.OrphanedSID | Should -BeNullOrEmpty
            $script:testResult.LikelySource | Should -BeNullOrEmpty
            $script:testResult.Confidence | Should -BeNullOrEmpty
            $script:testResult.AnalysisNotes | Should -BeNullOrEmpty
            $script:testResult.ProcessingMethod | Should -BeNullOrEmpty
            $script:testResult.ActionTaken | Should -BeNullOrEmpty
        }

        It "Should have default enum values" {
            # AccessControlType defaults to Allow (0)
            $script:testResult.AccessControlType | Should -Be ([System.Security.AccessControl.AccessControlType]::Allow)

            # ActiveDirectoryRights defaults to 0
            $script:testResult.ActiveDirectoryRights | Should -Be 0

            # InheritanceType defaults to None (0)
            $script:testResult.InheritanceType | Should -Be ([System.Security.AccessControl.InheritanceFlags]::None)
        }

        It "Should have empty GUID default values" {
            $script:testResult.ObjectType | Should -Be ([System.Guid]::Empty)
            $script:testResult.InheritedObjectType | Should -Be ([System.Guid]::Empty)
        }

        It "Should have false default for IsInherited" {
            $script:testResult.IsInherited | Should -Be $false
        }
    }

    Context "Integration Tests" {
        It "Should create complete OrphanedSIDResult object" {
            $result = [OrphanedSIDResult]::new()
            $objectType = [System.Guid]::NewGuid()
            $inheritedObjectType = [System.Guid]::NewGuid()

            # Set all properties
            $result.ObjectDN = "CN=TestUser,OU=Users,DC=example,DC=com"
            $result.ObjectClass = "user"
            $result.OrphanedSID = "S-1-5-21-1234567890-987654321-123456789-1001"
            $result.LikelySource = "Former Domain User"
            $result.Confidence = "High"
            $result.AnalysisNotes = "SID not found in current domain or any trusted domains"
            $result.AccessControlType = [System.Security.AccessControl.AccessControlType]::Deny
            $result.ActiveDirectoryRights = [System.DirectoryServices.ActiveDirectoryRights]::ReadProperty
            $result.InheritanceType = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit
            $result.ObjectType = $objectType
            $result.InheritedObjectType = $inheritedObjectType
            $result.IsInherited = $true
            $result.ProcessingMethod = "Automated Scan"
            $result.ActionTaken = "Removed from ACL"
            $result.VerificationStatus = 'Unverified'
            $result.VerificationError = 'Get-ADObject: server unavailable'

            # Verify all properties are set correctly
            $result.ObjectDN | Should -Be "CN=TestUser,OU=Users,DC=example,DC=com"
            $result.ObjectClass | Should -Be "user"
            $result.OrphanedSID | Should -Be "S-1-5-21-1234567890-987654321-123456789-1001"
            $result.LikelySource | Should -Be "Former Domain User"
            $result.Confidence | Should -Be "High"
            $result.AnalysisNotes | Should -Be "SID not found in current domain or any trusted domains"
            $result.AccessControlType | Should -Be ([System.Security.AccessControl.AccessControlType]::Deny)
            $result.ActiveDirectoryRights | Should -Be ([System.DirectoryServices.ActiveDirectoryRights]::ReadProperty)
            $result.InheritanceType | Should -Be ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit)
            $result.ObjectType | Should -Be $objectType
            $result.InheritedObjectType | Should -Be $inheritedObjectType
            $result.IsInherited | Should -Be $true
            $result.ProcessingMethod | Should -Be "Automated Scan"
            $result.ActionTaken | Should -Be "Removed from ACL"
            $result.VerificationStatus | Should -Be 'Unverified'
            $result.VerificationError | Should -Be 'Get-ADObject: server unavailable'
        }
    }
}

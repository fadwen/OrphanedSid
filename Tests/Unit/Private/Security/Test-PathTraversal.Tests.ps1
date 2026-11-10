#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
Describe "Test-PathTraversal" -Tag 'Unit', 'Private', 'Security' {
    BeforeAll {
        # Suppresses the function's "Path does not exist" warning
        $env:PESTER_TESTING = $true

        . "$PSScriptRoot\..\..\..\..\Private\Security\Test-PathTraversal.ps1"

        # Pester can only mock a command that exists, so the real Write-StructuredLog is loaded first
        . "$PSScriptRoot\..\..\..\..\Private\Logging\Write-StructuredLog.ps1"

        Mock Write-StructuredLog { }

        # The real cmdlet, for a Resolve-Path mock that only intercepts one path
        $script:RealResolvePath = Get-Command -Name Resolve-Path -CommandType Cmdlet

        # $env:TEMP is an 8.3 short path (RUNNER~1) on the GitHub runners; Get-Item expands it so the
        # paths the functions return, which are long, compare equal to the ones built here
        $script:TempRoot = (Get-Item -LiteralPath $env:TEMP).FullName
        $script:TestBasePath = Join-Path $script:TempRoot "PathTraversalTests"
        $script:OutsideDir = Join-Path $script:TempRoot "PathTraversalOutside"
        foreach ($dir in $script:TestBasePath, $script:OutsideDir) {
            if (Test-Path $dir) {
                Remove-Item $dir -Recurse -Force
            }
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
        }

        $script:SafeDir = Join-Path $script:TestBasePath "SafeDirectory"
        $script:NestedDir = Join-Path $script:SafeDir "Nested"
        New-Item -Path $script:NestedDir -ItemType Directory -Force | Out-Null

        $script:SafeFile = Join-Path $script:SafeDir "safe.txt"
        $script:NestedFile = Join-Path $script:NestedDir "nested.txt"
        $script:OutsideFile = Join-Path $script:OutsideDir "outside.txt"
        "Safe content" | Out-File $script:SafeFile
        "Nested content" | Out-File $script:NestedFile
        "Outside content" | Out-File $script:OutsideFile

        $script:ValidPaths = @($script:SafeFile, $script:NestedFile, $script:SafeDir, $script:NestedDir)
    }

    AfterAll {
        foreach ($dir in $script:TestBasePath, $script:OutsideDir, "$($script:TestBasePath)Evil") {
            if (Test-Path $dir) {
                Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        Remove-Item -Path "env:PESTER_TESTING" -ErrorAction SilentlyContinue
    }

    Context "Input" {
        It "Rejects a null path" {
            { Test-PathTraversal -Path $null -BasePath $script:TestBasePath } | Should -Throw "*Cannot bind argument to parameter 'Path' because it is null.*"
        }

        It "Throws for a base path that does not exist" {
            { Test-PathTraversal -Path $script:SafeFile -BasePath 'Z:\NonExistent\Path' } |
                Should -Throw -ExpectedMessage 'Invalid base path: Z:\NonExistent\Path*'
        }

        It "Uses the current location as the base path by default" {
            Push-Location $script:SafeDir
            try {
                $result = Test-PathTraversal -Path $script:SafeFile
            } finally {
                Pop-Location
            }

            $result.ValidationResults[0].BasePath | Should -Be $script:SafeDir
            $result.ValidationResults[0].IsSafe | Should -Be $true
        }

        It "Validates every path in an array passed by parameter" {
            $result = Test-PathTraversal -Path $script:ValidPaths -BasePath $script:TestBasePath

            $result.PSObject.TypeNames[0] | Should -Be 'PathTraversalValidationResult'
            $result.TotalPaths | Should -Be 4
            $result.SafePaths | Should -Be 4
            $result.ValidationPassed | Should -Be $true
            @($result.ValidationResults.OriginalPath) | Should -Be $script:ValidPaths
        }

        It "Validates every path from the pipeline into one result" {
            $result = Get-ChildItem $script:SafeDir -Recurse |
                Select-Object -ExpandProperty FullName |
                Test-PathTraversal -BasePath $script:TestBasePath

            @($result).Count | Should -Be 1
            $result.TotalPaths | Should -Be 3
            $result.SafePaths | Should -Be 3
            $result.ValidationPassed | Should -Be $true
        }
    }

    Context "Traversal patterns" {
        It "Flags the traversal pattern in '<Pattern>'" -ForEach @(
            @{ Pattern = '..\..\..\etc\passwd' }
            @{ Pattern = '../../etc/passwd' }
            @{ Pattern = '..%2f..%2fetc%2fpasswd' }
            @{ Pattern = '..%5c..%5cWindows' }
            @{ Pattern = '%2e%2e%2foutside.txt' }
            @{ Pattern = '%2E%2E%5Coutside.txt' }
        ) {
            $result = Test-PathTraversal -Path (Join-Path $script:SafeDir $Pattern) -BasePath $script:TestBasePath

            $result.ValidationResults[0].ContainsTraversalPattern | Should -Be $true
            $result.ValidationResults[0].IsSafe | Should -Be $false
            $result.ValidationPassed | Should -Be $false
        }

        It "Rejects a path with a traversal pattern even when it resolves inside the base path" {
            $path = "$script:SafeDir\..\SafeDirectory\safe.txt"

            $result = Test-PathTraversal -Path $path -BasePath $script:TestBasePath

            $result.ValidationResults[0].ResolvedPath | Should -Be $script:SafeFile
            $result.ValidationResults[0].IsWithinBasePath | Should -Be $true
            $result.ValidationResults[0].ContainsTraversalPattern | Should -Be $true
            $result.ValidationResults[0].IsSafe | Should -Be $false
        }
    }

    Context "Location relative to the base path" {
        It "Accepts files and directories inside the base path" {
            $result = Test-PathTraversal -Path $script:ValidPaths -BasePath $script:TestBasePath

            foreach ($validationResult in $result.ValidationResults) {
                $validationResult.IsWithinBasePath | Should -Be $true
                $validationResult.ContainsTraversalPattern | Should -Be $false
                $validationResult.IsSymbolicLink | Should -Be $false
                $validationResult.IsSafe | Should -Be $true
            }
        }

        It "Rejects an existing file outside the base path" {
            $result = Test-PathTraversal -Path $script:OutsideFile -BasePath $script:TestBasePath

            $result.ValidationResults[0].ResolvedPath | Should -Be $script:OutsideFile
            $result.ValidationResults[0].IsWithinBasePath | Should -Be $false
            $result.ValidationResults[0].IsSafe | Should -Be $false
        }

        It "Counts safe and unsafe paths separately in a mixed batch" {
            $mixedBatch = @(
                $script:SafeFile,
                $script:NestedFile,
                $script:OutsideFile,
                "$script:SafeDir\..\..\invalid.txt"
            )

            $result = Test-PathTraversal -Path $mixedBatch -BasePath $script:TestBasePath

            $result.TotalPaths | Should -Be 4
            $result.SafePaths | Should -Be 2
            $result.UnsafePaths | Should -Be 2
            $result.ValidationPassed | Should -Be $false
            @($result.ValidationResults.IsSafe) | Should -Be @($true, $true, $false, $false)
        }

        It "Treats a path that does not exist as unsafe" {
            $nonExistentPath = Join-Path $script:TestBasePath "nonexistent.txt"

            $result = Test-PathTraversal -Path $nonExistentPath -BasePath $script:TestBasePath

            $result.UnsafePaths | Should -Be 1
            $result.ValidationResults[0].ResolvedPath | Should -BeNullOrEmpty
            $result.ValidationResults[0].IsWithinBasePath | Should -Be $false
            $result.ValidationPassed | Should -Be $false
        }

        # Module bug (#24): on PowerShell 7 Item.Target is a string, so Target[0] is its first character and
        # a junction to C:\... resolves to <link folder>\C, inside the base path, and passes as safe.
        # Windows PowerShell 5.1 returns a collection and the test passes there.
        It "Judges a junction by its target, which lies outside the base path" -Skip:($PSVersionTable.PSVersion.Major -gt 5) {
            $linkPath = Join-Path $script:SafeDir "outsidelink"
            New-Item -ItemType Junction -Path $linkPath -Target $script:OutsideDir | Out-Null
            try {
                $result = Test-PathTraversal -Path $linkPath -BasePath $script:TestBasePath

                $result.ValidationResults[0].IsSymbolicLink | Should -Be $true
                $result.ValidationResults[0].FinalTargetPath | Should -Be $script:OutsideDir
                $result.ValidationResults[0].IsWithinBasePath | Should -Be $false
                $result.ValidationResults[0].IsSafe | Should -Be $false
                $result.ValidationPassed | Should -Be $false
            } finally {
                # Removing the junction itself, not the directory it points to
                [System.IO.Directory]::Delete($linkPath)
            }
        }

        # Module bug (#24): the containment check is a bare StartsWith on the base path, so a sibling folder
        # whose name begins with the base folder's name counts as inside it
        It "Rejects a sibling folder whose name starts with the base folder's name" -Skip {
            $sibling = "$($script:TestBasePath)Evil"
            New-Item -Path $sibling -ItemType Directory -Force | Out-Null

            $result = Test-PathTraversal -Path $sibling -BasePath $script:TestBasePath

            $result.ValidationResults[0].IsWithinBasePath | Should -Be $false
        }
    }

    Context "Errors" {
        It "Writes an error and counts the path unsafe when it cannot be resolved" {
            Mock Resolve-Path { & $script:RealResolvePath @PesterBoundParameters }
            Mock Resolve-Path { throw 'resolve failed' } -ParameterFilter { $Path -eq $script:SafeFile }

            $result = Test-PathTraversal -Path $script:SafeFile, $script:NestedFile -BasePath $script:TestBasePath -ErrorAction SilentlyContinue -ErrorVariable errors

            $result.TotalPaths | Should -Be 2
            $result.UnsafePaths | Should -Be 1
            $result.SafePaths | Should -Be 1
            $result.ValidationResults[0].IsSafe | Should -Be $false
            # -ErrorVariable also collects records Pester's mock plumbing writes, so pick out the function's
            @($errors | Where-Object { "$_" -eq "Error validating path $($script:SafeFile) : resolve failed" }).Count | Should -Be 1
        }
    }

    Context "Correlation and logging" {
        It "Stamps the caller's correlation ID on the result and every path result" {
            $result = Test-PathTraversal -Path $script:ValidPaths -BasePath $script:TestBasePath -CorrelationId 'path-1'

            $result.CorrelationId | Should -Be 'path-1'
            foreach ($validationResult in $result.ValidationResults) {
                $validationResult.CorrelationId | Should -Be 'path-1'
            }
        }

        It "Generates a GUID correlation ID when none is given" {
            $result = Test-PathTraversal -Path $script:SafeFile -BasePath $script:TestBasePath

            { [guid]::Parse($result.CorrelationId) } | Should -Not -Throw
        }

        It "Logs a passed validation at Information level with the summary" {
            Test-PathTraversal -Path $script:SafeFile -BasePath $script:TestBasePath -CorrelationId 'path-2' | Out-Null

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Information' -and $CorrelationId -eq 'path-2' -and
                $Data.TotalPaths -eq 1 -and $Data.SafePaths -eq 1 -and $Data.ValidationPassed -eq $true
            }
        }

        It "Logs a failed validation at Warning level with the summary" {
            Test-PathTraversal -Path $script:OutsideFile -BasePath $script:TestBasePath -CorrelationId 'path-3' | Out-Null

            Should -Invoke Write-StructuredLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and $CorrelationId -eq 'path-3' -and
                $Data.UnsafePaths -eq 1 -and $Data.ValidationPassed -eq $false
            }
        }
    }
}

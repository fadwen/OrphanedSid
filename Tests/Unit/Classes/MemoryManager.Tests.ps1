#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
BeforeAll {
    $ModuleRoot = Resolve-Path "$PSScriptRoot\..\..\.."

    . "$ModuleRoot\Classes\MemoryManager.ps1"
}

Describe "MemoryManager Class Tests" -Tag "Unit", "Classes", "MemoryManager" {

    Context "Constructor Tests" {
        It "Should create instance with new 3-argument constructor" {
            $correlationId = [System.Guid]::NewGuid().ToString()
            $manager = [MemoryManager]::new(100, 10, $correlationId)
            
            $manager | Should -Not -BeNullOrEmpty
            $manager.MaxMemoryMB | Should -Be 100
            $manager.CheckInterval | Should -Be 10
            $manager.CorrelationId | Should -Be $correlationId
            $manager.CheckCounter | Should -Be 0
            $manager.PeakMemoryUsage | Should -Be 0
            $manager.Disposed | Should -Be $false
            $manager.Timer | Should -Not -BeNullOrEmpty
            $manager.Timer.IsRunning | Should -Be $true
        }

        It "Should create instance with legacy 2-argument constructor" {
            $manager = [MemoryManager]::new(200, 20)
            
            $manager | Should -Not -BeNullOrEmpty
            $manager.MaxMemoryMB | Should -Be 200
            $manager.CheckInterval | Should -Be 20
            $manager.CorrelationId | Should -Not -BeNullOrEmpty
            $manager.CorrelationId | Should -Match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
            $manager.CheckCounter | Should -Be 0
            $manager.PeakMemoryUsage | Should -Be 0
            $manager.Disposed | Should -Be $false
            $manager.Timer | Should -Not -BeNullOrEmpty
            $manager.Timer.IsRunning | Should -Be $true
        }

        It "Should generate new CorrelationId when null provided to 3-argument constructor" {
            $manager = [MemoryManager]::new(100, 10, $null)
            
            $manager.CorrelationId | Should -Not -BeNullOrEmpty
            $manager.CorrelationId | Should -Match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
        }

        It "Should generate new CorrelationId when empty string provided to 3-argument constructor" {
            $manager = [MemoryManager]::new(100, 10, "")
            
            $manager.CorrelationId | Should -Not -BeNullOrEmpty
            $manager.CorrelationId | Should -Match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
        }
    }

    Context "CheckMemoryUsage Method Tests" {
        BeforeEach {
            $script:testManager = [MemoryManager]::new([int]::MaxValue, 3, [System.Guid]::NewGuid().ToString())
        }

        AfterEach {
            if ($script:testManager -and -not $script:testManager.Disposed) {
                $script:testManager.Dispose()
            }
        }

        It "Should increment CheckCounter on each call" {
            $initialCounter = $script:testManager.CheckCounter
            
            $script:testManager.CheckMemoryUsage()
            $script:testManager.CheckCounter | Should -Be ($initialCounter + 1)
            
            $script:testManager.CheckMemoryUsage()
            $script:testManager.CheckCounter | Should -Be ($initialCounter + 2)
        }

        It "Should reset CheckCounter when reaching CheckInterval" {
            # Set CheckCounter to CheckInterval - 1
            $script:testManager.CheckCounter = $script:testManager.CheckInterval - 1
            
            $script:testManager.CheckMemoryUsage()
            $script:testManager.CheckCounter | Should -Be 0
        }

        It "Should track peak memory usage" {
            $initialPeak = $script:testManager.PeakMemoryUsage
            
            # Force multiple memory checks to trigger peak tracking
            for ($i = 0; $i -lt $script:testManager.CheckInterval; $i++) {
                $script:testManager.CheckMemoryUsage()
            }
            
            $script:testManager.PeakMemoryUsage | Should -BeGreaterThan $initialPeak
        }

        It "Should not perform memory check when disposed" {
            $script:testManager.Dispose()
            $initialCounter = $script:testManager.CheckCounter
            
            $script:testManager.CheckMemoryUsage()
            $script:testManager.CheckCounter | Should -Be $initialCounter
        }

        It "Should turn a Get-Process failure into a warning carrying the correlation ID" {
            # A check interval of 1 makes the first call read the process memory
            $testManager = [MemoryManager]::new(50, 1, 'cid-getprocess')

            # Not a Pester mock: on Windows PowerShell 5.1 a class method resolves commands in the
            # scope where the class was first defined, so when another file in the run loaded
            # MemoryManager first, a mock here never reaches it. A global function shadows the
            # cmdlet from every scope; it is removed as soon as the call returns.
            ${function:global:Get-Process} = { throw 'Process not found' }
            try {
                $warnings = @(& { $testManager.CheckMemoryUsage() } 3>&1)
            }
            finally {
                # Without a scope in the path, Remove-Item takes the first match, the global one.
                # "Function:\global:Get-Process" silently removes nothing on Windows PowerShell 5.1.
                Remove-Item -LiteralPath 'Function:\Get-Process'
            }
            (Get-Command -Name Get-Process).CommandType | Should -Be 'Cmdlet'

            $warnings.Count | Should -Be 1
            $warnings[0].Message | Should -BeLike 'Failed to check memory usage: Process not found*CorrelationId: cid-getprocess'
            $testManager.PeakMemoryUsage | Should -Be 0

            $testManager.Dispose()
        }

        It "Should warn with the limit and correlation ID when the memory limit is exceeded" {
            # A 1 MB limit is below any real working set, so the over-limit branch runs
            $lowMemoryManager = [MemoryManager]::new(1, 1, 'cid-overlimit')

            $warnings = @(& { $lowMemoryManager.CheckMemoryUsage() } 3>&1)

            $warnings[0].Message | Should -BeLike 'Memory usage threshold exceeded:*(Limit: 1 MB) - CorrelationId: cid-overlimit'
            # The working set stays above 1 MB after collection, so the second warning follows
            $warnings[1].Message | Should -BeLike 'Memory usage still exceeds limit after garbage collection:*CorrelationId: cid-overlimit'
            $lowMemoryManager.PeakMemoryUsage | Should -BeGreaterThan 1

            $lowMemoryManager.Dispose()
        }

        It "Should not warn when memory is under the limit" {
            $manager = [MemoryManager]::new([int]::MaxValue, 1, [System.Guid]::NewGuid().ToString())

            $warnings = @(& { $manager.CheckMemoryUsage() } 3>&1)

            $warnings.Count | Should -Be 0
            $manager.PeakMemoryUsage | Should -BeGreaterThan 0

            $manager.Dispose()
        }
    }

    Context "GetPeakMemoryUsage Method Tests" {
        BeforeEach {
            $script:testManager = [MemoryManager]::new([int]::MaxValue, 5, [System.Guid]::NewGuid().ToString())
        }

        AfterEach {
            if ($script:testManager -and -not $script:testManager.Disposed) {
                $script:testManager.Dispose()
            }
        }

        It "Should return the recorded peak memory usage" {
            $script:testManager.PeakMemoryUsage = 1234

            $peakUsage = $script:testManager.GetPeakMemoryUsage()
            $peakUsage | Should -Be 1234
            $peakUsage | Should -BeOfType [long]
        }

        It "Should return zero initially" {
            $peakUsage = $script:testManager.GetPeakMemoryUsage()
            $peakUsage | Should -Be 0
        }

        It "Should reflect updated peak after memory checks" {
            # Force memory checks to update peak
            for ($i = 0; $i -lt $script:testManager.CheckInterval; $i++) {
                $script:testManager.CheckMemoryUsage()
            }
            
            $peakUsage = $script:testManager.GetPeakMemoryUsage()
            $peakUsage | Should -BeGreaterThan 0
        }
    }

    Context "Dispose Method Tests" {
        It "Should properly dispose resources" {
            $manager = [MemoryManager]::new(100, 10, [System.Guid]::NewGuid().ToString())
            
            $manager.Disposed | Should -Be $false
            $manager.Timer | Should -Not -BeNullOrEmpty
            
            $manager.Dispose()
            
            $manager.Disposed | Should -Be $true
            $manager.Timer | Should -BeNullOrEmpty
        }

        It "Should be safe to call Dispose multiple times" {
            $manager = [MemoryManager]::new(100, 10, [System.Guid]::NewGuid().ToString())

            { $manager.Dispose() } | Should -Not -Throw
            { $manager.Dispose() } | Should -Not -Throw

            $manager.Disposed | Should -Be $true
        }

        It "Should stop timer when disposing" {
            $manager = [MemoryManager]::new(100, 10, [System.Guid]::NewGuid().ToString())
            # Hold the stopwatch, because Dispose clears the property
            $timer = $manager.Timer
            $timer.IsRunning | Should -Be $true

            $manager.Dispose()

            $timer.IsRunning | Should -Be $false
        }
    }

    Context "Property Validation Tests" {
        BeforeEach {
            $script:testManager = [MemoryManager]::new(150, 25, "test-correlation-id")
        }

        AfterEach {
            if ($script:testManager -and -not $script:testManager.Disposed) {
                $script:testManager.Dispose()
            }
        }

        It "Should have correct property types" {
            $script:testManager.MaxMemoryMB | Should -BeOfType [int]
            $script:testManager.CheckInterval | Should -BeOfType [int]
            $script:testManager.CheckCounter | Should -BeOfType [int]
            $script:testManager.Timer | Should -BeOfType [System.Diagnostics.Stopwatch]
            $script:testManager.PeakMemoryUsage | Should -BeOfType [long]
            $script:testManager.Disposed | Should -BeOfType [bool]
            $script:testManager.CorrelationId | Should -BeOfType [string]
        }

        It "Should maintain property values" {
            $script:testManager.MaxMemoryMB | Should -Be 150
            $script:testManager.CheckInterval | Should -Be 25
            $script:testManager.CorrelationId | Should -Be "test-correlation-id"
        }
    }

    Context "Integration Tests" {
        It "Should manage memory through complete lifecycle" {
            $manager = [MemoryManager]::new([int]::MaxValue, 2, [System.Guid]::NewGuid().ToString())
            
            # Initial state
            $manager.CheckCounter | Should -Be 0
            $manager.PeakMemoryUsage | Should -Be 0
            $manager.Disposed | Should -Be $false
            
            # Perform memory checks
            $manager.CheckMemoryUsage()
            $manager.CheckCounter | Should -Be 1
            
            $manager.CheckMemoryUsage()
            $manager.CheckCounter | Should -Be 0  # Should reset after reaching interval
            
            # The second call read the process memory, so a peak is recorded
            $peakUsage = $manager.GetPeakMemoryUsage()
            $peakUsage | Should -BeGreaterThan 0

            # Dispose properly
            $manager.Dispose()
            $manager.Disposed | Should -Be $true
        }

        It "Should check memory on every call when the interval is zero" {
            $manager = [MemoryManager]::new([int]::MaxValue, 0, [System.Guid]::NewGuid().ToString())

            $manager.CheckMemoryUsage()

            $manager.CheckCounter | Should -Be 0
            $manager.PeakMemoryUsage | Should -BeGreaterThan 0

            $manager.Dispose()
        }
    }

    Context "Error Handling Tests" {
        It "Should keep negative constructor values and treat a negative limit as exceeded" {
            $manager = [MemoryManager]::new(-100, -10, 'cid-negative')

            $manager.MaxMemoryMB | Should -Be -100
            $manager.CheckInterval | Should -Be -10

            # A negative interval checks on every call, and any working set exceeds a negative limit
            $warnings = @(& { $manager.CheckMemoryUsage() } 3>&1)

            $manager.CheckCounter | Should -Be 0
            $warnings[0].Message | Should -BeLike 'Memory usage threshold exceeded:*(Limit: -100 MB)*cid-negative'

            $manager.Dispose()
        }
    }
}


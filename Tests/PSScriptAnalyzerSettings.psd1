@{
    # Relaxed rule set for Tests/ and Tools/. The shipping code (Classes, Private, Public, Build,
    # the root module and manifest) runs with every Error and Warning rule and no settings file;
    # see .github/workflows/quality-gates.yml. These exclusions exist because each of these rules
    # fires on the shape a Pester test file necessarily has, not on a defect:
    #
    #   PSReviewUnusedParameter               Stub and mock functions declare the real command's
    #                                         parameters so -ParameterFilter can bind to them.
    #   PSUseDeclaredVarsMoreThanAssignments  Values set in BeforeAll are read inside It blocks,
    #                                         which the analyzer treats as separate scopes.
    #   PSAvoidGlobalVars                     ADCmdletStubs.ps1 and the mock factory define global
    #                                         placeholders so Pester can mock commands that are
    #                                         absent without RSAT.
    #   PSUseShouldProcessForStateChangingFunctions
    #                                         Mock bodies named after the commands they replace.
    #   PSAvoidUsingEmptyCatchBlock           Teardown that must not fail the test on cleanup.
    #   PSUseUsingScopeModifierInNewRunspaces Tests that exercise runspace-related code paths.
    #   PSAvoidUsingConvertToSecureStringWithPlainText, PSAvoidUsingUsernameAndPasswordParams,
    #   PSAvoidUsingPlainTextForPassword      Tools/Generate-OrphanedSIDs.ps1 seeds a disposable
    #                                         lab domain with throwaway credentials.
    #   PSAvoidUsingInvokeExpression          The same lab script builds AD filters dynamically.
    #   PSAvoidUsingWriteHost                 The lab script is interactive console output.
    #   PSUseSingularNouns                    Helper names such as New-ADMocks describe a set.
    #   PSUseSupportsShouldProcess, PSShouldProcess, PSAvoidOverwritingBuiltInCmdlets,
    #   PSUseProcessBlockForPipelineCommand   Mock bodies are named after, and shaped like, the
    #                                         commands they replace.
    #   PSAvoidUsingBrokenHashAlgorithms      Get-StringHash.Tests exercises the MD5 and SHA1
    #                                         options the function offers for legacy checksums.
    #   PSPossibleIncorrectComparisonWithNull Assertions written as `$value -ne $null` read as the
    #                                         test intends; the collection case does not apply.
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        'PSReviewUnusedParameter'
        'PSUseDeclaredVarsMoreThanAssignments'
        'PSAvoidGlobalVars'
        'PSUseShouldProcessForStateChangingFunctions'
        'PSAvoidUsingEmptyCatchBlock'
        'PSUseUsingScopeModifierInNewRunspaces'
        'PSAvoidUsingConvertToSecureStringWithPlainText'
        'PSAvoidUsingUsernameAndPasswordParams'
        'PSAvoidUsingPlainTextForPassword'
        'PSAvoidUsingInvokeExpression'
        'PSAvoidUsingWriteHost'
        'PSUseSingularNouns'
        'PSUseSupportsShouldProcess'
        'PSShouldProcess'
        'PSAvoidOverwritingBuiltInCmdlets'
        'PSUseProcessBlockForPipelineCommand'
        'PSAvoidUsingBrokenHashAlgorithms'
        'PSPossibleIncorrectComparisonWithNull'
    )
}

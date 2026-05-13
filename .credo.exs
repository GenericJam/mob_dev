%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      strict: true,
      checks: %{
        enabled: [
          {Credo.Check.Readability.Specs, files: %{excluded: ["test/"]}},
          {Credo.Check.Refactor.UnlessWithElse, []},
          # ex_slop — runs the recommended bundle of AI-slop checks.
          {ExSlop, []},
          # jump_credo_checks — general
          {Jump.CredoChecks.AvoidFunctionLevelElse, []},
          {Jump.CredoChecks.AvoidLoggerConfigureInTest, []},
          {Jump.CredoChecks.TestHasNoAssertions, []},
          {Jump.CredoChecks.TooManyAssertions, []},
          {Jump.CredoChecks.TopLevelAliasImportRequire, []},
          {Jump.CredoChecks.WeakAssertion, []},
          {Jump.CredoChecks.VacuousTest, []},
          # jump_credo_checks — LiveView specific
          {Jump.CredoChecks.AssertElementSelectorCanNeverFail, []},
          {Jump.CredoChecks.AvoidSocketAssignsInTest, []},
          {Jump.CredoChecks.LiveViewFormCanBeRehydrated, []}
        ],
        disabled: [
          # Pipes with single function calls are fine in this codebase
          {Credo.Check.Readability.SinglePipe, []}
        ]
      }
    }
  ]
}

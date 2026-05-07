defmodule MobDev.SecurityScan.LayerResult do
  @moduledoc """
  Result of running a single scan layer (Hex deps, Gradle deps,
  bundled runtime, C source, etc).

  `status` is one of:

    * `:ok` — layer ran successfully (findings may still be empty)
    * `:tool_missing` — a required external scanner isn't installed;
      the layer was skipped with a warning
    * `:not_applicable` — the surface area doesn't exist in this project
      (e.g. no `android/` directory)
    * `:skipped` — the user passed `--skip <name>`
    * `:error` — the layer failed unexpectedly; see `:error` field

  Layers always return a LayerResult; they never raise. Callers
  decide how to surface tool-missing or error states based on
  whether the scan is in `--strict` mode.
  """

  alias MobDev.SecurityScan.Finding

  @type status :: :ok | :tool_missing | :not_applicable | :skipped | :error

  @type t :: %__MODULE__{
          name: atom(),
          status: status(),
          findings: [Finding.t()],
          tools_used: [String.t()],
          duration_ms: non_neg_integer() | nil,
          error: String.t() | nil,
          notes: [String.t()]
        }

  @derive Jason.Encoder
  defstruct name: nil,
            status: :ok,
            findings: [],
            tools_used: [],
            duration_ms: nil,
            error: nil,
            notes: []
end

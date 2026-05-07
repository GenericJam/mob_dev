defmodule MobDev.SecurityScan.Layer do
  @moduledoc """
  Behaviour every scan layer implements.

  A layer's job is to produce a `LayerResult` for one slice of the
  attack surface (Hex deps, Gradle deps, bundled OpenSSL, ...).
  Layers must never raise; failures are reported as
  `%LayerResult{status: :error, error: "..."}` so the rest of the
  scan continues.

  A layer is responsible for deciding whether its surface area
  exists in the current project (e.g. the Gradle layer returns
  `:not_applicable` when there's no `android/` directory). The
  runner does not gate layers on project shape.
  """

  alias MobDev.SecurityScan.LayerResult

  @type opts :: keyword()

  @callback name() :: atom()
  @callback run(opts()) :: LayerResult.t()
end

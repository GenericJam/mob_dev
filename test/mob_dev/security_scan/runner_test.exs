defmodule MobDev.SecurityScan.RunnerTest do
  use ExUnit.Case, async: true

  alias MobDev.SecurityScan.{Finding, LayerResult, Runner}

  defmodule OkLayer do
    @behaviour MobDev.SecurityScan.Layer

    @impl true
    def name, do: :ok_layer

    @impl true
    def run(_opts) do
      %LayerResult{
        name: :ok_layer,
        status: :ok,
        findings: [%Finding{id: "X", severity: :high, layer: :ok_layer}]
      }
    end
  end

  defmodule RaisingLayer do
    @behaviour MobDev.SecurityScan.Layer

    @impl true
    def name, do: :raising_layer

    @impl true
    def run(_opts), do: raise("boom")
  end

  defmodule SlowLayer do
    @behaviour MobDev.SecurityScan.Layer

    @impl true
    def name, do: :slow_layer

    @impl true
    def run(_opts) do
      Process.sleep(15)
      %LayerResult{name: :slow_layer, status: :ok}
    end
  end

  test "runs every layer and accumulates findings" do
    report = Runner.run([OkLayer])

    assert [%LayerResult{name: :ok_layer, status: :ok, findings: [_one]}] =
             report.layers
  end

  test "wraps a raising layer as :error so other layers still run" do
    report = Runner.run([RaisingLayer, OkLayer])

    assert [%LayerResult{name: :raising_layer, status: :error, error: "boom"}, ok] =
             report.layers

    assert ok.name == :ok_layer
    assert ok.status == :ok
  end

  test "skip flag marks layers without invoking them" do
    pid = self()

    defmodule TattleLayer do
      @behaviour MobDev.SecurityScan.Layer
      @impl true
      def name, do: :tattle
      @impl true
      def run(opts) do
        send(opts[:_pid], :ran)
        %LayerResult{name: :tattle, status: :ok}
      end
    end

    report = Runner.run([TattleLayer], skip: [:tattle], _pid: pid)

    refute_received :ran
    assert [%LayerResult{name: :tattle, status: :skipped}] = report.layers
  end

  test "records duration_ms for each layer" do
    report = Runner.run([SlowLayer])
    [layer] = report.layers
    assert layer.duration_ms >= 15
  end

  test "fires on_layer_start and on_layer_done callbacks" do
    pid = self()

    Runner.run([OkLayer],
      on_layer_start: fn name -> send(pid, {:start, name}) end,
      on_layer_done: fn result -> send(pid, {:done, result.name, result.status}) end
    )

    assert_received {:start, :ok_layer}
    assert_received {:done, :ok_layer, :ok}
  end
end

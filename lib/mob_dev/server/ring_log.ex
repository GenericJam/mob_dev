defmodule MobDev.Server.RingLog do
  @moduledoc false

  # Shared GenServer behaviour for in-memory ring-buffer log holders.
  # `LogBuffer` and `ElixirLogBuffer` differ only in their limit; both
  # `use MobDev.Server.RingLog, limit: N` to get the standard
  # `get/0`, `push/1`, `clear/0` API plus the GenServer callbacks.

  defmacro __using__(opts) do
    limit = Keyword.fetch!(opts, :limit)

    quote bind_quoted: [limit: limit] do
      use GenServer

      @limit limit

      @spec start_link(keyword()) :: GenServer.on_start()
      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      end

      @spec get() :: [map()]
      def get, do: GenServer.call(__MODULE__, :get)

      @spec push(map()) :: :ok
      def push(line), do: GenServer.cast(__MODULE__, {:push, line})

      @spec clear() :: :ok
      def clear, do: GenServer.cast(__MODULE__, :clear)

      @impl GenServer
      def init(_), do: {:ok, []}

      @impl GenServer
      def handle_call(:get, _from, lines), do: {:reply, lines, lines}

      @impl GenServer
      def handle_cast({:push, line}, lines), do: {:noreply, Enum.take([line | lines], @limit)}
      def handle_cast(:clear, _lines), do: {:noreply, []}
    end
  end
end

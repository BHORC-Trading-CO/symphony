defmodule SymphonyElixir.Agent do
  @moduledoc """
  Adapter boundary for coding-agent execution.

  An agent adapter implements three callbacks (`start_session/2`, `run_turn/4`,
  `stop_session/1`) and is registered under a string `kind` in the adapter
  registry. The active adapter is selected by `agent.kind` in the workflow
  config.

  ## Registering custom adapters

  Built-in adapters live in `builtin_adapters/0`. Additional adapters can be
  registered at runtime via:

      Application.put_env(:symphony_elixir, :agent_adapters, %{
        "gemini" => MyApp.Gemini.AppServer
      })

  Runtime overrides take precedence over built-ins on key collision.
  """

  alias SymphonyElixir.{Config, Issue}

  @type session :: term()
  @type turn_result :: %{required(:session_id) => String.t(), optional(atom()) => term()}

  @callback start_session(workspace :: Path.t(), opts :: keyword()) ::
              {:ok, session()} | {:error, term()}

  @callback run_turn(session(), prompt :: String.t(), issue :: Issue.t(), opts :: keyword()) ::
              {:ok, turn_result()} | {:error, term()}

  @callback stop_session(session()) :: :ok

  @builtin_adapters %{
    "codex" => SymphonyElixir.Codex.AppServer
  }

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    adapter().start_session(workspace, opts)
  end

  @spec run_turn(session(), String.t(), Issue.t(), keyword()) ::
          {:ok, turn_result()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []) do
    adapter().run_turn(session, prompt, issue, opts)
  end

  @spec stop_session(session()) :: :ok
  def stop_session(session) do
    adapter().stop_session(session)
  end

  @spec adapter() :: module()
  def adapter do
    adapter_for!(configured_kind())
  end

  @spec adapter_for!(String.t()) :: module()
  def adapter_for!(kind) when is_binary(kind) do
    case Map.fetch(adapters(), kind) do
      {:ok, module} ->
        module

      :error ->
        raise ArgumentError,
              "no agent adapter registered for kind: #{inspect(kind)}. registered kinds: #{inspect(Map.keys(adapters()))}"
    end
  end

  @spec adapters() :: %{required(String.t()) => module()}
  def adapters do
    overrides = Application.get_env(:symphony_elixir, :agent_adapters, %{})
    Map.merge(@builtin_adapters, overrides)
  end

  @spec builtin_adapters() :: %{required(String.t()) => module()}
  def builtin_adapters, do: @builtin_adapters

  defp configured_kind do
    case Config.settings!().agent.kind do
      kind when is_binary(kind) and kind != "" -> kind
      _ -> "codex"
    end
  end
end

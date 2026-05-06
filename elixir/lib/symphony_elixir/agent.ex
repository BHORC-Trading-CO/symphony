defmodule SymphonyElixir.Agent do
  @moduledoc """
  Adapter boundary for coding-agent execution.

  An agent adapter implements three callbacks (`start_session/2`, `run_turn/4`,
  `stop_session/1`) and is registered under a string `kind` in the adapter
  registry. The active adapter is selected by `agent.kind` (or per-issue when
  `agent.routing == "by_label"`) in the workflow config.

  Calls into this module return a wrapped session that carries the adapter
  module forward, so subsequent `run_turn/3` and `stop_session/1` calls
  dispatch to the same adapter that handled `start_session/2` regardless of
  whether the configured kind has changed in the meantime.

  ## Registering custom adapters

  Built-in adapters live in `builtin_adapters/0`. Additional adapters can be
  registered at runtime via:

      Application.put_env(:symphony_elixir, :agent_adapters, %{
        "gemini" => MyApp.Gemini.AppServer
      })

  Runtime overrides take precedence over built-ins on key collision.
  """

  alias SymphonyElixir.{Config, Issue}

  @type adapter_session :: term()
  @type wrapped_session :: %{required(:__agent_adapter__) => module(), required(:session) => adapter_session()}
  @type turn_result :: %{required(:session_id) => String.t(), optional(atom()) => term()}

  @callback start_session(workspace :: Path.t(), opts :: keyword()) ::
              {:ok, adapter_session()} | {:error, term()}

  @callback run_turn(adapter_session(), prompt :: String.t(), issue :: Issue.t(), opts :: keyword()) ::
              {:ok, turn_result()} | {:error, term()}

  @callback stop_session(adapter_session()) :: :ok

  @builtin_adapters %{
    "codex" => SymphonyElixir.Codex.AppServer,
    "claude_code" => SymphonyElixir.ClaudeCode.AppServer
  }

  @label_prefix "agent:"

  @spec start_session(Path.t(), keyword()) :: {:ok, wrapped_session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    {kind, adapter_opts} = Keyword.pop(opts, :agent_kind)
    {adapter_module, kind_for_log} = resolve_adapter(kind)

    case adapter_module.start_session(workspace, adapter_opts) do
      {:ok, adapter_session} ->
        {:ok, %{__agent_adapter__: adapter_module, __agent_kind__: kind_for_log, session: adapter_session}}

      other ->
        other
    end
  end

  @spec run_turn(wrapped_session(), String.t(), Issue.t(), keyword()) ::
          {:ok, turn_result()} | {:error, term()}
  def run_turn(%{__agent_adapter__: adapter_module, session: adapter_session}, prompt, issue, opts \\ []) do
    adapter_module.run_turn(adapter_session, prompt, issue, opts)
  end

  @spec stop_session(wrapped_session()) :: :ok
  def stop_session(%{__agent_adapter__: adapter_module, session: adapter_session}) do
    adapter_module.stop_session(adapter_session)
  end

  @doc """
  Resolves the agent kind that should handle a given issue.

  When `agent.routing` is `"by_label"`, looks for the first label of the form
  `agent:<kind>` (case-insensitive) and falls back to the configured default
  kind when no such label is present. Other routing modes return the
  configured default kind.
  """
  @spec resolve_kind_for_issue(Issue.t()) :: String.t()
  def resolve_kind_for_issue(%Issue{} = issue) do
    settings = Config.settings!()
    default = configured_kind(settings)

    case settings.agent.routing do
      "by_label" -> kind_from_labels(issue.labels) || default
      _ -> default
    end
  end

  def resolve_kind_for_issue(_issue), do: configured_kind()

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

  defp resolve_adapter(nil), do: {adapter(), configured_kind()}

  defp resolve_adapter(""), do: {adapter(), configured_kind()}

  defp resolve_adapter(kind) when is_binary(kind), do: {adapter_for!(kind), kind}

  defp configured_kind, do: configured_kind(Config.settings!())

  defp configured_kind(settings) do
    case settings.agent.kind do
      kind when is_binary(kind) and kind != "" -> kind
      _ -> "codex"
    end
  end

  defp kind_from_labels(labels) when is_list(labels) do
    labels
    |> Enum.map(&label_to_kind/1)
    |> Enum.find(& &1)
  end

  defp kind_from_labels(_labels), do: nil

  defp label_to_kind(label) when is_binary(label) do
    normalized = label |> String.trim() |> String.downcase()

    if String.starts_with?(normalized, @label_prefix) do
      kind = String.replace_prefix(normalized, @label_prefix, "")
      if kind == "", do: nil, else: kind
    else
      nil
    end
  end

  defp label_to_kind(_label), do: nil
end

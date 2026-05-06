defmodule SymphonyElixir.ClaudeCode.AppServer do
  @moduledoc """
  Claude Code agent adapter.

  Implements `SymphonyElixir.Agent` by spawning the `claude` CLI in
  `--output-format stream-json --verbose` mode, parsing each JSONL event,
  and forwarding normalized progress messages back to the orchestrator
  through the `:on_message` callback supplied via `run_turn/4` opts.

  Authentication is delegated to the host environment: the adapter relies on
  `claude login` having been run on the machine where Symphony is executing.
  No API key is required when using an Anthropic Pro/Max subscription. This
  adapter does not support remote (SSH) execution; runs are always local.

  Each call to `run_turn/4` invokes a fresh `claude -p <prompt>` subprocess.
  Sessions are not reused across turns; this is acceptable because the
  orchestrator loops `run_turn/4` only when an issue still needs more work,
  and each turn carries the full prompt context.
  """

  @behaviour SymphonyElixir.Agent

  require Logger
  alias SymphonyElixir.{Config, PathSafety}

  @default_command "claude"
  @line_chunk_bytes 1_048_576
  @default_turn_timeout_ms 3_600_000
  @non_json_log_capture 50
  @non_json_log_line_bytes 4_000

  @type session :: %{
          workspace: Path.t(),
          worker_host: nil
        }

  @impl true
  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    case Keyword.get(opts, :worker_host) do
      nil ->
        with {:ok, expanded} <- validate_workspace(workspace) do
          {:ok, %{workspace: expanded, worker_host: nil}}
        end

      _host ->
        {:error, :claude_code_remote_workers_unsupported}
    end
  end

  @impl true
  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(%{workspace: workspace}, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, fn _ -> :ok end)
    timeout_ms = Keyword.get(opts, :turn_timeout_ms, @default_turn_timeout_ms)

    case open_port(workspace, prompt) do
      {:ok, port} ->
        try do
          consume_events(port, on_message, issue, %{}, "", timeout_ms)
        after
          close_port(port)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  @spec stop_session(session()) :: :ok
  def stop_session(_session), do: :ok

  ## ----- Test seams -----

  @doc false
  @spec parse_event_for_test(String.t()) :: {:ok, map()} | {:error, term()}
  def parse_event_for_test(line), do: parse_event(line)

  @doc false
  @spec normalize_message_for_test(map(), map()) :: {:ok, map()} | :ignore
  def normalize_message_for_test(event, issue), do: normalize_message(event, issue)

  ## ----- Internals -----

  defp validate_workspace(workspace) do
    case PathSafety.canonicalize(workspace) do
      {:ok, expanded} ->
        if File.dir?(expanded) do
          {:ok, expanded}
        else
          {:error, {:claude_code_invalid_workspace, expanded}}
        end

      {:error, reason} ->
        {:error, {:claude_code_invalid_workspace, reason}}
    end
  end

  defp open_port(workspace, prompt) do
    {command, base_args} = command_with_args()
    args = base_args ++ ["-p", prompt]

    case System.find_executable(command) do
      nil ->
        {:error, {:claude_code_executable_missing, command}}

      abs_command ->
        spawn_port(abs_command, args, workspace)
    end
  end

  defp spawn_port(abs_command, args, workspace) do
    port =
      Port.open({:spawn_executable, abs_command}, [
        :binary,
        :exit_status,
        :hide,
        :stderr_to_stdout,
        {:line, @line_chunk_bytes},
        {:cd, workspace},
        {:args, args}
      ])

    {:ok, port}
  rescue
    error -> {:error, {:claude_code_spawn_failed, Exception.message(error)}}
  end

  defp consume_events(port, on_message, issue, accumulated_state, partial_line, timeout_ms) do
    receive do
      {^port, {:data, {flag, chunk}}} ->
        line = partial_line <> chunk

        case flag do
          :eol ->
            new_state = handle_line(line, on_message, issue, accumulated_state)
            consume_events(port, on_message, issue, new_state, "", timeout_ms)

          :noeol ->
            consume_events(port, on_message, issue, accumulated_state, line, timeout_ms)
        end

      {^port, {:exit_status, status}} ->
        finalize_turn(accumulated_state, status)
    after
      timeout_ms ->
        {:error, :claude_code_turn_timeout}
    end
  end

  defp handle_line(line, on_message, issue, state) do
    case parse_event(line) do
      {:ok, event} ->
        state = capture_state(event, state)

        case normalize_message(event, issue) do
          {:ok, message} ->
            emit(on_message, message)
            state

          :ignore ->
            state
        end

      {:error, _reason} ->
        capture_non_json_line(state, line)
    end
  end

  defp capture_non_json_line(state, line) do
    trimmed = line |> String.trim() |> truncate_line()

    if trimmed == "" do
      state
    else
      existing = Map.get(state, :non_json_lines, [])
      capped = Enum.take([trimmed | existing], @non_json_log_capture)
      Map.put(state, :non_json_lines, capped)
    end
  end

  defp truncate_line(line) when is_binary(line) do
    if byte_size(line) > @non_json_log_line_bytes do
      binary_part(line, 0, @non_json_log_line_bytes) <> "...<truncated>"
    else
      line
    end
  end

  defp capture_state(%{"type" => "system", "subtype" => "init", "session_id" => session_id}, state),
    do: Map.put(state, :session_id, session_id)

  defp capture_state(%{"type" => "result"} = event, state) do
    state
    |> Map.put(:result, Map.get(event, "result"))
    |> Map.put(:session_id, Map.get(event, "session_id") || Map.get(state, :session_id))
    |> Map.put(:is_error, Map.get(event, "is_error", false))
    |> Map.put(:terminal_reason, Map.get(event, "terminal_reason"))
  end

  defp capture_state(_event, state), do: state

  defp normalize_message(%{"type" => "system", "subtype" => "init", "session_id" => session_id} = event, _issue) do
    {:ok,
     %{
       kind: :session_started,
       session_id: session_id,
       model: Map.get(event, "model"),
       cwd: Map.get(event, "cwd")
     }}
  end

  defp normalize_message(%{"type" => "assistant", "message" => %{"content" => content}}, _issue)
       when is_list(content) do
    text =
      content
      |> Enum.flat_map(fn
        %{"type" => "text", "text" => text} when is_binary(text) -> [text]
        _ -> []
      end)
      |> Enum.join("")

    if text == "" do
      :ignore
    else
      {:ok, %{kind: :agent_message, text: text}}
    end
  end

  defp normalize_message(%{"type" => "result"} = event, _issue) do
    {:ok,
     %{
       kind: :turn_completed,
       session_id: Map.get(event, "session_id"),
       result: Map.get(event, "result"),
       is_error: Map.get(event, "is_error", false),
       duration_ms: Map.get(event, "duration_ms"),
       num_turns: Map.get(event, "num_turns")
     }}
  end

  defp normalize_message(_event, _issue), do: :ignore

  defp parse_event(line) when is_binary(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        {:error, :empty_line}

      not String.starts_with?(trimmed, "{") ->
        {:error, :not_json}

      true ->
        case Jason.decode(trimmed) do
          {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
          {:ok, _other} -> {:error, :not_object}
          {:error, reason} -> {:error, {:json_decode, reason}}
        end
    end
  end

  defp emit(on_message, message) when is_function(on_message, 1) do
    on_message.(message)
  end

  defp emit(_on_message, _message), do: :ok

  defp finalize_turn(state, exit_status) do
    cond do
      exit_status != 0 ->
        {:error,
         {:claude_code_exit_nonzero, exit_status,
          %{
            result: Map.get(state, :result),
            captured_output: state |> Map.get(:non_json_lines, []) |> Enum.reverse()
          }}}

      Map.get(state, :is_error, false) == true ->
        {:error,
         {:claude_code_turn_error,
          %{
            result: Map.get(state, :result),
            captured_output: state |> Map.get(:non_json_lines, []) |> Enum.reverse()
          }}}

      true ->
        session_id = Map.get(state, :session_id) || generate_fallback_session_id()

        {:ok,
         %{
           result: Map.get(state, :result),
           session_id: session_id,
           thread_id: session_id,
           turn_id: session_id
         }}
    end
  end

  defp generate_fallback_session_id, do: "claude-#{System.unique_integer([:positive])}"

  defp close_port(port) do
    if Port.info(port) do
      Port.close(port)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp command_with_args do
    settings = Config.settings!()
    raw_command = settings.claude_code.command
    parts = OptionParser.split(raw_command)

    case parts do
      [head | rest] -> {head, rest ++ default_args(settings)}
      [] -> {@default_command, default_args(settings)}
    end
  end

  defp default_args(settings) do
    [
      "--output-format",
      "stream-json",
      "--verbose",
      "--permission-mode",
      settings.claude_code.permission_mode,
      "--max-turns",
      Integer.to_string(settings.claude_code.max_turns_per_invocation)
    ]
  end
end

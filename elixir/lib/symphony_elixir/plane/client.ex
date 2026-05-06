defmodule SymphonyElixir.Plane.Client do
  @moduledoc """
  Thin Plane REST client used by `SymphonyElixir.Plane.Adapter`.

  The Plane public API (https://api.plane.so by default, configurable for
  self-hosted) is paginated by cursor and does not honor server-side state
  filtering for the issue list endpoint, so we paginate fully and filter in
  Elixir using state IDs resolved from the project's states list.
  """

  require Logger
  alias SymphonyElixir.{Config, Issue}

  @default_endpoint "https://api.plane.so"
  @issue_page_size 100
  @max_error_body_log_bytes 1_000

  @type http_response :: {:ok, map()} | {:error, term()}

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    settings = Config.settings!()
    fetch_issues_by_state_names(settings.tracker.active_states, settings)
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    fetch_issues_by_state_names(state_names, Config.settings!())
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    settings = Config.settings!()

    with {:ok, metadata} <- load_metadata(settings) do
      collect_issues_by_id(issue_ids, settings, metadata)
    end
  end

  defp collect_issues_by_id(issue_ids, settings, metadata) do
    issue_ids
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
      fetch_issue_by_id_step(id, settings, metadata, acc)
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      other -> other
    end
  end

  defp fetch_issue_by_id_step(id, settings, metadata, acc) do
    case do_get(issues_path(settings, id), settings) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        issue =
          normalize_issue(
            body,
            metadata.state_id_to_name,
            metadata.label_id_to_name,
            metadata.project_identifier,
            settings
          )

        {:cont, {:ok, [issue | acc]}}

      {:ok, %{status: 404}} ->
        {:cont, {:ok, acc}}

      {:ok, %{status: status} = response} ->
        {:halt, {:error, {:plane_unexpected_status, status, plane_error_context(response)}}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body)
      when is_binary(issue_id) and is_binary(body) do
    settings = Config.settings!()
    path = issue_comments_path(settings, issue_id)

    case do_post(path, %{"comment_html" => body}, settings) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status} = response} -> {:error, {:plane_comment_failed, status, plane_error_context(response)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    settings = Config.settings!()

    with {:ok, %{state_name_to_id: name_to_id}} <- load_metadata(settings),
         {:ok, state_id} <- resolve_state_id(name_to_id, state_name),
         path = issues_path(settings, issue_id),
         {:ok, %{status: status} = response} <- do_patch(path, %{"state" => state_id}, settings) do
      if status in 200..299 do
        :ok
      else
        {:error, {:plane_update_failed, status, plane_error_context(response)}}
      end
    end
  end

  ## ----- Test seams -----

  @doc false
  @spec normalize_issue_for_test(map(), %{String.t() => String.t()}, %{String.t() => String.t()}, String.t() | nil) ::
          Issue.t()
  def normalize_issue_for_test(issue_payload, state_id_to_name, label_id_to_name, project_identifier) do
    normalize_issue(issue_payload, state_id_to_name, label_id_to_name, project_identifier, Config.settings!())
  end

  ## ----- Internals -----

  defp fetch_issues_by_state_names(state_names, settings) when is_list(state_names) do
    with {:ok, metadata} <- load_metadata(settings) do
      requested_ids = resolve_state_ids(state_names, metadata.state_name_to_id)

      cond do
        state_names == [] -> {:ok, []}
        MapSet.size(requested_ids) == 0 -> {:ok, []}
        true -> fetch_and_filter_issues(settings, metadata, requested_ids)
      end
    end
  end

  defp resolve_state_ids(state_names, name_to_id) do
    state_names
    |> Enum.map(&normalize_state_name/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Map.get(name_to_id, &1))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp fetch_and_filter_issues(settings, metadata, requested_ids) do
    case fetch_all_issues(settings) do
      {:ok, raw_issues} ->
        filtered =
          raw_issues
          |> Enum.filter(fn issue -> MapSet.member?(requested_ids, Map.get(issue, "state")) end)
          |> Enum.map(&normalize_issue(&1, metadata.state_id_to_name, metadata.label_id_to_name, metadata.project_identifier, settings))

        {:ok, filtered}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_all_issues(settings) do
    fetch_issue_pages(settings, nil, [])
  end

  defp fetch_issue_pages(settings, cursor, acc) do
    path = issues_index_path(settings, cursor)

    case do_get(path, settings) do
      {:ok, %{status: 200, body: %{"results" => results} = body}} when is_list(results) ->
        next_cursor =
          if Map.get(body, "next_page_results") == true do
            Map.get(body, "next_cursor")
          else
            nil
          end

        new_acc = acc ++ results

        case next_cursor do
          cursor when is_binary(cursor) and cursor != "" ->
            fetch_issue_pages(settings, cursor, new_acc)

          _ ->
            {:ok, new_acc}
        end

      {:ok, %{status: status} = response} ->
        {:error, {:plane_unexpected_status, status, plane_error_context(response)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_metadata(settings) do
    with {:ok, states} <- fetch_states(settings),
         {:ok, labels} <- fetch_labels(settings),
         {:ok, project_identifier} <- fetch_project_identifier(settings) do
      state_id_to_name = Map.new(states, fn s -> {Map.get(s, "id"), Map.get(s, "name")} end)
      state_name_to_id = Map.new(states, fn s -> {normalize_state_name(Map.get(s, "name")), Map.get(s, "id")} end)
      label_id_to_name = Map.new(labels, fn l -> {Map.get(l, "id"), Map.get(l, "name")} end)

      {:ok,
       %{
         state_id_to_name: state_id_to_name,
         state_name_to_id: state_name_to_id,
         label_id_to_name: label_id_to_name,
         project_identifier: project_identifier
       }}
    end
  end

  defp fetch_states(settings) do
    case do_get(states_path(settings), settings) do
      {:ok, %{status: 200, body: %{"results" => results}}} when is_list(results) ->
        {:ok, results}

      {:ok, %{status: status} = response} ->
        {:error, {:plane_states_unavailable, status, plane_error_context(response)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_labels(settings) do
    case do_get(labels_path(settings), settings) do
      {:ok, %{status: 200, body: %{"results" => results}}} when is_list(results) ->
        {:ok, results}

      {:ok, %{status: status} = response} ->
        {:error, {:plane_labels_unavailable, status, plane_error_context(response)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_project_identifier(settings) do
    case do_get(project_path(settings), settings) do
      {:ok, %{status: 200, body: %{"identifier" => identifier}}} when is_binary(identifier) ->
        {:ok, identifier}

      {:ok, %{status: status} = response} ->
        {:error, {:plane_project_unavailable, status, plane_error_context(response)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_issue(issue, state_id_to_name, label_id_to_name, project_identifier, settings) do
    state_id = Map.get(issue, "state")
    state_name = Map.get(state_id_to_name, state_id)

    label_ids = issue |> Map.get("labels", []) |> List.wrap()

    label_names =
      label_ids
      |> Enum.map(fn
        %{"name" => name} when is_binary(name) -> name
        id when is_binary(id) -> Map.get(label_id_to_name, id)
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    assignee_ids = issue |> Map.get("assignees", []) |> List.wrap()
    assignee_id = first_assignee_id(assignee_ids)
    assigned_to_worker = assignee_matches?(assignee_ids, settings.tracker.assignee)

    sequence_id = Map.get(issue, "sequence_id")
    identifier = compose_identifier(project_identifier, sequence_id)

    %Issue{
      id: Map.get(issue, "id"),
      identifier: identifier,
      title: Map.get(issue, "name"),
      description: Map.get(issue, "description_stripped") || Map.get(issue, "description_html"),
      priority: priority_to_int(Map.get(issue, "priority")),
      state: state_name,
      branch_name: nil,
      url: nil,
      assignee_id: assignee_id,
      blocked_by: [],
      labels: label_names,
      assigned_to_worker: assigned_to_worker,
      created_at: parse_datetime(Map.get(issue, "created_at")),
      updated_at: parse_datetime(Map.get(issue, "updated_at"))
    }
  end

  defp first_assignee_id([]), do: nil

  defp first_assignee_id([%{"id" => id} | _]) when is_binary(id), do: id

  defp first_assignee_id([id | _]) when is_binary(id), do: id

  defp first_assignee_id(_), do: nil

  defp assignee_matches?(_assignees, nil), do: true

  defp assignee_matches?(_assignees, ""), do: true

  defp assignee_matches?(assignees, configured) when is_binary(configured) do
    Enum.any?(assignees, fn
      %{"id" => id} when is_binary(id) -> id == configured
      id when is_binary(id) -> id == configured
      _ -> false
    end)
  end

  defp compose_identifier(prefix, sequence_id) when is_binary(prefix) and is_integer(sequence_id),
    do: "#{prefix}-#{sequence_id}"

  defp compose_identifier(_prefix, _sequence_id), do: nil

  defp priority_to_int("urgent"), do: 1
  defp priority_to_int("high"), do: 2
  defp priority_to_int("medium"), do: 3
  defp priority_to_int("low"), do: 4
  defp priority_to_int("none"), do: 0
  defp priority_to_int(_), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp resolve_state_id(name_to_id, state_name) when is_binary(state_name) do
    case Map.get(name_to_id, normalize_state_name(state_name)) do
      id when is_binary(id) -> {:ok, id}
      _ -> {:error, :state_not_found}
    end
  end

  defp normalize_state_name(value) when is_binary(value) do
    value |> String.trim() |> String.downcase()
  end

  defp normalize_state_name(_), do: ""

  ## ----- HTTP -----

  defp do_get(path, settings) do
    Req.get(url(settings, path), headers: headers(settings), connect_options: [timeout: 30_000])
  end

  defp do_post(path, body, settings) do
    Req.post(url(settings, path), headers: headers(settings), json: body, connect_options: [timeout: 30_000])
  end

  defp do_patch(path, body, settings) do
    Req.patch(url(settings, path), headers: headers(settings), json: body, connect_options: [timeout: 30_000])
  end

  defp url(settings, path) do
    base = endpoint_base(settings.tracker.endpoint)
    base <> path
  end

  defp endpoint_base(nil), do: @default_endpoint

  defp endpoint_base(endpoint) when is_binary(endpoint) do
    cond do
      String.trim(endpoint) == "" -> @default_endpoint
      String.contains?(endpoint, "linear.app") -> @default_endpoint
      true -> String.trim_trailing(endpoint, "/")
    end
  end

  defp headers(settings) do
    [
      {"X-API-Key", settings.tracker.api_key},
      {"Content-Type", "application/json"},
      {"Accept", "application/json"}
    ]
  end

  defp issues_index_path(settings, cursor) do
    base = "/api/v1/workspaces/#{settings.tracker.workspace_slug}/projects/#{settings.tracker.project_slug}/issues/?per_page=#{@issue_page_size}"

    case cursor do
      cursor when is_binary(cursor) and cursor != "" -> base <> "&cursor=" <> URI.encode_www_form(cursor)
      _ -> base
    end
  end

  defp issues_path(settings, issue_id),
    do: "/api/v1/workspaces/#{settings.tracker.workspace_slug}/projects/#{settings.tracker.project_slug}/issues/#{issue_id}/"

  defp issue_comments_path(settings, issue_id),
    do: "/api/v1/workspaces/#{settings.tracker.workspace_slug}/projects/#{settings.tracker.project_slug}/issues/#{issue_id}/comments/"

  defp states_path(settings),
    do: "/api/v1/workspaces/#{settings.tracker.workspace_slug}/projects/#{settings.tracker.project_slug}/states/"

  defp labels_path(settings),
    do: "/api/v1/workspaces/#{settings.tracker.workspace_slug}/projects/#{settings.tracker.project_slug}/labels/"

  defp project_path(settings),
    do: "/api/v1/workspaces/#{settings.tracker.workspace_slug}/projects/#{settings.tracker.project_slug}/"

  defp plane_error_context(response) do
    body = response |> Map.get(:body) |> summarize_error_body()
    " body=" <> body
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end
end

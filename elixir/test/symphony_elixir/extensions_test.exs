defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Plane.Adapter, as: PlaneAdapter
  alias SymphonyElixir.Plane.Client, as: PlaneClient
  alias SymphonyElixir.Tracker.Memory

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeLinearClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  defmodule FakePlaneClient do
    def fetch_candidate_issues do
      send(self(), :plane_fetch_candidate_issues_called)
      {:ok, [:plane_candidate]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:plane_fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:plane_fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def create_comment(issue_id, body) do
      send(self(), {:plane_create_comment_called, issue_id, body})
      :ok
    end

    def update_issue_state(issue_id, state_name) do
      send(self(), {:plane_update_issue_state_called, issue_id, state_name})
      :ok
    end
  end

  defmodule FakeAgentAdapter do
    @behaviour SymphonyElixir.Agent

    @impl true
    def start_session(workspace, opts) do
      send(self(), {:fake_agent_start_session, workspace, opts})
      {:ok, %{workspace: workspace, opts: opts}}
    end

    @impl true
    def run_turn(session, prompt, issue, opts) do
      send(self(), {:fake_agent_run_turn, session, prompt, issue, opts})
      {:ok, %{session_id: "fake-session-1", thread_id: "fake-thread", turn_id: "fake-turn"}}
    end

    @impl true
    def stop_session(session) do
      send(self(), {:fake_agent_stop_session, session})
      :ok
    end
  end

  defmodule BrokenAgentAdapter do
    @behaviour SymphonyElixir.Agent

    @impl true
    def start_session(_workspace, _opts), do: {:error, :start_session_failed}

    @impl true
    def run_turn(_session, _prompt, _issue, _opts), do: {:error, :run_turn_failed}

    @impl true
    def stop_session(_session), do: :ok
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)
    plane_client_module = Application.get_env(:symphony_elixir, :plane_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end

      if is_nil(plane_client_module) do
        Application.delete_env(:symphony_elixir, :plane_client_module)
      else
        Application.put_env(:symphony_elixir, :plane_client_module, plane_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Second prompt")
    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    File.write!(Workflow.workflow_file_path(), "---\ntracker: [\n---\nBroken prompt\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "THIRD_WORKFLOW.md")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
  end

  test "workflow store init stops on missing workflow file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_WORKFLOW.md")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "MANUAL_WORKFLOW.md")
    missing_path = Path.join(Path.dirname(existing_path), "MANUAL_MISSING_WORKFLOW.md")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    Workflow.set_workflow_file_path(missing_path)

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    File.write!(manual_path, "---\ntracker: [\n---\nBroken prompt\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Process.exit(manual_pid, :normal)
    restart_result = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

    assert match?({:ok, _pid}, restart_result) or
             match?({:error, {:already_started, _pid}}, restart_result)

    Workflow.set_workflow_file_path(existing_path)
    WorkflowStore.force_reload()
  end

  test "tracker delegates to memory and linear adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, %{id: "ignored"}])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.settings!().tracker.kind == "memory"
    assert SymphonyElixir.Tracker.adapter() == Memory
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_candidate_issues()
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issue_states_by_ids(["issue-1"])
    assert :ok = SymphonyElixir.Tracker.create_comment("issue-1", "comment")
    assert :ok = SymphonyElixir.Tracker.update_issue_state("issue-1", "Done")
    assert_receive {:memory_tracker_comment, "issue-1", "comment"}
    assert_receive {:memory_tracker_state_update, "issue-1", "Done"}

    Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    assert :ok = Memory.create_comment("issue-1", "quiet")
    assert :ok = Memory.update_issue_state("issue-1", "Quiet")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert SymphonyElixir.Tracker.adapter() == Adapter
  end

  test "linear adapter delegates reads and validates mutation responses" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues()
    assert_receive :fetch_candidate_issues_called

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = Adapter.fetch_issue_states_by_ids(["issue-1"])
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-1"]}

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    )

    assert :ok = Adapter.create_comment("issue-1", "hello")
    assert_receive {:graphql_called, create_comment_query, %{body: "hello", issueId: "issue-1"}}
    assert create_comment_query =~ "commentCreate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    )

    assert {:error, :comment_create_failed} =
             Adapter.create_comment("issue-1", "broken")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})

    assert {:error, :boom} = Adapter.create_comment("issue-1", "boom")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "weird")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "odd")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.update_issue_state("issue-1", "Done")
    assert_receive {:graphql_called, state_lookup_query, %{issueId: "issue-1", stateName: "Done"}}
    assert state_lookup_query =~ "states"

    assert_receive {:graphql_called, update_issue_query, %{issueId: "issue-1", stateId: "state-1"}}

    assert update_issue_query =~ "issueUpdate"

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}
      ]
    )

    assert {:error, :issue_update_failed} =
             Adapter.update_issue_state("issue-1", "Broken")

    Process.put({FakeLinearClient, :graphql_results}, [{:error, :boom}])

    assert {:error, :boom} = Adapter.update_issue_state("issue-1", "Boom")

    Process.put({FakeLinearClient, :graphql_results}, [{:ok, %{"data" => %{}}}])
    assert {:error, :state_not_found} = Adapter.update_issue_state("issue-1", "Missing")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{}}}
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Weird")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        :unexpected
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Odd")
  end

  test "tracker dispatches to plane adapter when kind=plane" do
    Application.put_env(:symphony_elixir, :plane_client_module, FakePlaneClient)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "plane",
      tracker_endpoint: "https://api.plane.so",
      tracker_api_token: "plane-token",
      tracker_workspace_slug: "bhorc",
      tracker_project_slug: "9f54069d-079b-4f3e-bed6-5c461298a64f"
    )

    assert SymphonyElixir.Tracker.adapter() == PlaneAdapter

    assert {:ok, [:plane_candidate]} = SymphonyElixir.Tracker.fetch_candidate_issues()
    assert_receive :plane_fetch_candidate_issues_called

    assert {:ok, ["Ready for dev"]} = SymphonyElixir.Tracker.fetch_issues_by_states(["Ready for dev"])
    assert_receive {:plane_fetch_issues_by_states_called, ["Ready for dev"]}

    assert {:ok, ["issue-1"]} = SymphonyElixir.Tracker.fetch_issue_states_by_ids(["issue-1"])
    assert_receive {:plane_fetch_issue_states_by_ids_called, ["issue-1"]}

    assert :ok = SymphonyElixir.Tracker.create_comment("issue-1", "hello from symphony")
    assert_receive {:plane_create_comment_called, "issue-1", "hello from symphony"}

    assert :ok = SymphonyElixir.Tracker.update_issue_state("issue-1", "Done")
    assert_receive {:plane_update_issue_state_called, "issue-1", "Done"}
  end

  test "plane config validation requires kind-specific fields" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "plane",
      tracker_api_token: nil,
      tracker_workspace_slug: nil,
      tracker_project_slug: nil
    )

    # Missing api_key fails first.
    assert {:error, :missing_plane_api_token} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "plane",
      tracker_api_token: "tok",
      tracker_workspace_slug: nil,
      tracker_project_slug: nil
    )

    assert {:error, :missing_plane_workspace_slug} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "plane",
      tracker_api_token: "tok",
      tracker_workspace_slug: "bhorc",
      tracker_project_slug: nil
    )

    assert {:error, :missing_plane_project_slug} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "plane",
      tracker_api_token: "tok",
      tracker_workspace_slug: "bhorc",
      tracker_project_slug: "proj"
    )

    assert :ok = Config.validate!()
  end

  test "plane env var fallbacks resolve PLANE_API_KEY and PLANE_ASSIGNEE" do
    previous_api_key = System.get_env("PLANE_API_KEY")
    previous_assignee = System.get_env("PLANE_ASSIGNEE")
    System.put_env("PLANE_API_KEY", "plane-fallback-key")
    System.put_env("PLANE_ASSIGNEE", "plane-fallback-assignee")

    on_exit(fn ->
      restore_env("PLANE_API_KEY", previous_api_key)
      restore_env("PLANE_ASSIGNEE", previous_assignee)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "plane",
      tracker_api_token: nil,
      tracker_assignee: nil,
      tracker_workspace_slug: "bhorc",
      tracker_project_slug: "proj"
    )

    settings = Config.settings!()
    assert settings.tracker.api_key == "plane-fallback-key"
    assert settings.tracker.assignee == "plane-fallback-assignee"
  end

  test "plane client normalizes a Plane work item into a SymphonyElixir.Issue" do
    # Configure a minimal plane workflow so Config.settings!() succeeds when
    # called from inside the normalize helper.
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "plane",
      tracker_api_token: "tok",
      tracker_workspace_slug: "bhorc",
      tracker_project_slug: "proj",
      tracker_assignee: "assignee-uuid-1"
    )

    payload = %{
      "id" => "issue-uuid-1",
      "name" => "Investigate rate limit on buy orders",
      "description_stripped" => "Some orders are throttled.",
      "description_html" => "<p>Some orders are throttled.</p>",
      "priority" => "urgent",
      "state" => "state-uuid-active",
      "sequence_id" => 380,
      "assignees" => ["assignee-uuid-1"],
      "labels" => ["label-uuid-bug"],
      "created_at" => "2026-05-05T16:10:49.849847Z",
      "updated_at" => "2026-05-05T16:12:01.589946Z"
    }

    issue =
      PlaneClient.normalize_issue_for_test(
        payload,
        %{"state-uuid-active" => "Ready for dev"},
        %{"label-uuid-bug" => "bug"},
        "SKINS"
      )

    assert %Issue{
             id: "issue-uuid-1",
             identifier: "SKINS-380",
             title: "Investigate rate limit on buy orders",
             description: "Some orders are throttled.",
             priority: 1,
             state: "Ready for dev",
             assignee_id: "assignee-uuid-1",
             labels: ["bug"],
             assigned_to_worker: true
           } = issue

    refute is_nil(issue.created_at)
    refute is_nil(issue.updated_at)

    # An issue assigned to a different user is not routed to this worker.
    other_assignee_payload = Map.put(payload, "assignees", ["someone-else"])

    issue_other =
      PlaneClient.normalize_issue_for_test(
        other_assignee_payload,
        %{"state-uuid-active" => "Ready for dev"},
        %{},
        "SKINS"
      )

    refute issue_other.assigned_to_worker
  end

  test "agent registry resolves built-in adapters, custom overrides, and unknown kinds" do
    write_workflow_file!(Workflow.workflow_file_path(), [])

    assert SymphonyElixir.Agent.builtin_adapters() == %{
             "codex" => SymphonyElixir.Codex.AppServer,
             "claude_code" => SymphonyElixir.ClaudeCode.AppServer
           }

    assert SymphonyElixir.Agent.adapter() == SymphonyElixir.Codex.AppServer

    Application.put_env(:symphony_elixir, :agent_adapters, %{"fake" => FakeAgentAdapter})

    on_exit(fn -> Application.delete_env(:symphony_elixir, :agent_adapters) end)

    assert SymphonyElixir.Agent.adapter_for!("fake") == FakeAgentAdapter
    assert SymphonyElixir.Agent.adapter_for!("codex") == SymphonyElixir.Codex.AppServer
    assert SymphonyElixir.Agent.adapter_for!("claude_code") == SymphonyElixir.ClaudeCode.AppServer

    assert_raise ArgumentError, ~r/no agent adapter registered/, fn ->
      SymphonyElixir.Agent.adapter_for!("missing")
    end
  end

  test "agent module delegates start_session/run_turn/stop_session to the configured adapter" do
    Application.put_env(:symphony_elixir, :agent_adapters, %{"fake" => FakeAgentAdapter})
    write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "fake")
    issue = %Issue{id: "issue-9", identifier: "AG-9", state: "In Progress"}

    on_exit(fn -> Application.delete_env(:symphony_elixir, :agent_adapters) end)

    assert SymphonyElixir.Agent.adapter() == FakeAgentAdapter

    # Default-args path (opts omitted).
    assert {:ok, default_wrapped} = SymphonyElixir.Agent.start_session("/tmp/ws-default")
    assert default_wrapped.__agent_adapter__ == FakeAgentAdapter
    default_inner = default_wrapped.session
    assert_receive {:fake_agent_start_session, "/tmp/ws-default", []}

    assert {:ok, _} = SymphonyElixir.Agent.run_turn(default_wrapped, "p", issue)
    assert_receive {:fake_agent_run_turn, ^default_inner, "p", ^issue, []}

    # Explicit-opts path. The :agent_kind option is consumed by Agent and not
    # forwarded to the adapter, while other opts pass through unchanged.
    assert {:ok, wrapped} = SymphonyElixir.Agent.start_session("/tmp/ws", worker_host: nil, agent_kind: "fake")
    inner = wrapped.session
    assert_receive {:fake_agent_start_session, "/tmp/ws", worker_host: nil}

    assert {:ok, %{session_id: "fake-session-1"}} =
             SymphonyElixir.Agent.run_turn(wrapped, "prompt body", issue, on_message: fn _ -> :ok end)

    assert_receive {:fake_agent_run_turn, ^inner, "prompt body", ^issue, _opts}

    assert :ok = SymphonyElixir.Agent.stop_session(wrapped)
    assert_receive {:fake_agent_stop_session, ^inner}
  end

  test "agent module falls back to codex kind when configured kind is empty" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "")
    assert SymphonyElixir.Agent.adapter() == SymphonyElixir.Codex.AppServer
  end

  test "agent.resolve_kind_for_issue routes by label when configured" do
    Application.put_env(:symphony_elixir, :agent_adapters, %{"fake" => FakeAgentAdapter})

    on_exit(fn -> Application.delete_env(:symphony_elixir, :agent_adapters) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "codex",
      agent_routing: "by_label"
    )

    # Label-driven kind takes precedence.
    issue_claude = %Issue{id: "i-1", identifier: "X-1", labels: ["agent:claude_code"]}
    assert SymphonyElixir.Agent.resolve_kind_for_issue(issue_claude) == "claude_code"

    issue_fake = %Issue{id: "i-2", identifier: "X-2", labels: ["agent:fake", "wip"]}
    assert SymphonyElixir.Agent.resolve_kind_for_issue(issue_fake) == "fake"

    # No agent:* label -> falls back to configured kind.
    issue_none = %Issue{id: "i-3", identifier: "X-3", labels: ["wip"]}
    assert SymphonyElixir.Agent.resolve_kind_for_issue(issue_none) == "codex"

    # Empty label list also falls back.
    issue_empty = %Issue{id: "i-4", identifier: "X-4", labels: []}
    assert SymphonyElixir.Agent.resolve_kind_for_issue(issue_empty) == "codex"

    # When routing is fixed, labels are ignored even if present.
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "codex",
      agent_routing: "fixed"
    )

    assert SymphonyElixir.Agent.resolve_kind_for_issue(issue_claude) == "codex"

    # Non-Issue inputs still resolve to configured kind.
    assert SymphonyElixir.Agent.resolve_kind_for_issue(%{not: :an_issue}) == "codex"

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "codex",
      agent_routing: "by_label"
    )

    # Non-binary labels and nil label list both fall back without crashing.
    issue_nil = %Issue{id: "i-5", identifier: "X-5", labels: nil}
    assert SymphonyElixir.Agent.resolve_kind_for_issue(issue_nil) == "codex"

    issue_atom = %Issue{id: "i-6", identifier: "X-6", labels: [:not_a_string]}
    assert SymphonyElixir.Agent.resolve_kind_for_issue(issue_atom) == "codex"

    # Empty agent: prefix is treated as no match.
    issue_empty_prefix = %Issue{id: "i-7", identifier: "X-7", labels: ["agent:"]}
    assert SymphonyElixir.Agent.resolve_kind_for_issue(issue_empty_prefix) == "codex"
  end

  test "agent.start_session forwards adapter errors and accepts blank agent_kind" do
    Application.put_env(:symphony_elixir, :agent_adapters, %{
      "fake" => FakeAgentAdapter,
      "broken" => BrokenAgentAdapter
    })

    on_exit(fn -> Application.delete_env(:symphony_elixir, :agent_adapters) end)

    write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "fake")

    # Blank kind opt -> falls back to configured default.
    assert {:ok, wrapped} = SymphonyElixir.Agent.start_session("/tmp/blank-kind", agent_kind: "")
    assert wrapped.__agent_adapter__ == FakeAgentAdapter
    assert_receive {:fake_agent_start_session, "/tmp/blank-kind", []}

    # Adapter-level error tuple flows back unchanged (not wrapped).
    assert {:error, :start_session_failed} =
             SymphonyElixir.Agent.start_session("/tmp/broken", agent_kind: "broken")
  end

  test "phoenix observability api preserves state, issue, and refresh responses" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ObservabilityApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)

    assert state_payload == %{
             "generated_at" => state_payload["generated_at"],
             "counts" => %{"running" => 1, "retrying" => 1},
             "running" => [
               %{
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "state" => "In Progress",
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "session_id" => "thread-http",
                 "turn_count" => 7,
                 "last_event" => "notification",
                 "last_message" => "rendered",
                 "started_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "last_event_at" => nil,
                 "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
               }
             ],
             "retrying" => [
               %{
                 "issue_id" => "issue-retry",
                 "issue_identifier" => "MT-RETRY",
                 "attempt" => 2,
                 "due_at" => state_payload["retrying"] |> List.first() |> Map.fetch!("due_at"),
                 "error" => "boom",
                 "worker_host" => nil,
                 "workspace_path" => nil
               }
             ],
             "codex_totals" => %{
               "input_tokens" => 4,
               "output_tokens" => 8,
               "total_tokens" => 12,
               "seconds_running" => 42.5
             },
             "rate_limits" => %{"primary" => %{"remaining" => 11}}
           }

    conn = get(build_conn(), "/api/v1/MT-HTTP")
    issue_payload = json_response(conn, 200)

    assert issue_payload == %{
             "issue_identifier" => "MT-HTTP",
             "issue_id" => "issue-http",
             "status" => "running",
             "workspace" => %{
               "path" => Path.join(Config.settings!().workspace.root, "MT-HTTP"),
               "host" => nil
             },
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => %{
               "worker_host" => nil,
               "workspace_path" => nil,
               "session_id" => "thread-http",
               "turn_count" => 7,
               "state" => "In Progress",
               "started_at" => issue_payload["running"]["started_at"],
               "last_event" => "notification",
               "last_message" => "rendered",
               "last_event_at" => nil,
               "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
             },
             "retry" => nil,
             "logs" => %{"codex_session_logs" => []},
             "recent_events" => [],
             "last_error" => nil,
             "tracked" => %{}
           }

    conn = get(build_conn(), "/api/v1/MT-RETRY")

    assert %{"status" => "retrying", "retry" => %{"attempt" => 2, "error" => "boom"}} =
             json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-MISSING")

    assert json_response(conn, 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }

    conn = post(build_conn(), "/api/v1/refresh", %{})

    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} =
             json_response(conn, 202)
  end

  test "phoenix observability api preserves 405, 404, and unavailable behavior" do
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

    assert json_response(post(build_conn(), "/api/v1/state", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/refresh"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/MT-1", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/unknown"), 404) ==
             %{"error" => %{"code" => "not_found", "message" => "Route not found"}}

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state_payload ==
             %{
               "generated_at" => state_payload["generated_at"],
               "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}
             }

    assert json_response(post(build_conn(), "/api/v1/refresh", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }
  end

  test "phoenix observability api preserves snapshot timeout behavior" do
    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    start_test_endpoint(orchestrator: timeout_orchestrator, snapshot_timeout_ms: 1)

    timeout_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert timeout_payload ==
             %{
               "generated_at" => timeout_payload["generated_at"],
               "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}
             }
  end

  test "dashboard bootstraps liveview from embedded static assets" do
    orchestrator_name = Module.concat(__MODULE__, :AssetOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    html = html_response(get(build_conn(), "/"), 200)
    assert html =~ "/dashboard.css"
    assert html =~ "/vendor/phoenix_html/phoenix_html.js"
    assert html =~ "/vendor/phoenix/phoenix.js"
    assert html =~ "/vendor/phoenix_live_view/phoenix_live_view.js"
    refute html =~ "/assets/app.js"
    refute html =~ "<style>"

    dashboard_css = response(get(build_conn(), "/dashboard.css"), 200)
    assert dashboard_css =~ ":root {"
    assert dashboard_css =~ ".status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-offline"

    phoenix_html_js = response(get(build_conn(), "/vendor/phoenix_html/phoenix_html.js"), 200)
    assert phoenix_html_js =~ "phoenix.link.click"

    phoenix_js = response(get(build_conn(), "/vendor/phoenix/phoenix.js"), 200)
    assert phoenix_js =~ "var Phoenix = (() => {"

    live_view_js =
      response(get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.js"), 200)

    assert live_view_js =~ "var LiveView = (() => {"
  end

  test "dashboard liveview renders and refreshes over pubsub" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
    snapshot = static_snapshot()

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Operations Dashboard"
    assert html =~ "MT-HTTP"
    assert html =~ "MT-RETRY"
    assert html =~ "rendered"
    assert html =~ "Runtime"
    assert html =~ "Live"
    assert html =~ "Offline"
    assert html =~ "Copy ID"
    assert html =~ "Codex update"
    refute html =~ "data-runtime-clock="
    refute html =~ "setInterval(refreshRuntimeClocks"
    refute html =~ "Refresh now"
    refute html =~ "Transport"
    assert html =~ "status-badge-live"
    assert html =~ "status-badge-offline"

    updated_snapshot =
      put_in(snapshot.running, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 8,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              payload: %{
                "method" => "codex/event/agent_message_content_delta",
                "params" => %{
                  "msg" => %{
                    "content" => "structured update"
                  }
                }
              }
            }
          },
          last_codex_timestamp: DateTime.utc_now(),
          codex_input_tokens: 10,
          codex_output_tokens: 12,
          codex_total_tokens: 22,
          started_at: DateTime.utc_now()
        }
      ])

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_snapshot)
    end)

    StatusDashboard.notify_update()

    assert_eventually(fn ->
      render(view) =~ "agent message content streaming: structured update"
    end)
  end

  test "dashboard liveview renders an unavailable state without crashing" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingDashboardOrchestrator),
      snapshot_timeout_ms: 5
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Snapshot unavailable"
    assert html =~ "snapshot_unavailable"
  end

  test "http server serves embedded assets, accepts form posts, and rejects invalid hosts" do
    spec = HttpServer.child_spec(port: 0)
    assert spec.id == HttpServer
    assert spec.start == {HttpServer, :start_link, [[port: 0]]}

    assert :ignore = HttpServer.start_link(port: nil)
    assert HttpServer.bound_port() == nil

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :BoundPortOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})

    start_supervised!({HttpServer, server_opts})

    port = wait_for_bound_port()
    assert port == HttpServer.bound_port()

    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert response.status == 200
    assert response.body["counts"] == %{"running" => 1, "retrying" => 1}

    dashboard_css = Req.get!("http://127.0.0.1:#{port}/dashboard.css")
    assert dashboard_css.status == 200
    assert dashboard_css.body =~ ":root {"

    phoenix_js = Req.get!("http://127.0.0.1:#{port}/vendor/phoenix/phoenix.js")
    assert phoenix_js.status == 200
    assert phoenix_js.body =~ "var Phoenix = (() => {"

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert refresh_response.status == 202
    assert refresh_response.body["queued"] == true

    method_not_allowed_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/state",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert method_not_allowed_response.status == 405
    assert method_not_allowed_response.body["error"]["code"] == "method_not_allowed"

    assert {:error, _reason} = HttpServer.start_link(host: "bad host", port: 0)
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp static_snapshot do
    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 7,
          codex_app_server_pid: nil,
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          codex_input_tokens: 4,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom"
        }
      ],
      codex_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      rate_limits: %{"primary" => %{"remaining" => 11}}
    }
  end

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      case Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end
end

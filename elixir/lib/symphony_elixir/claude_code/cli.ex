defmodule SymphonyElixir.ClaudeCode.CLI do
  @moduledoc """
  Adapter that drives the Claude Code CLI in headless streaming mode.

  Each turn invokes one `claude --print --output-format stream-json --verbose`
  subprocess. The first turn captures the Claude session_id from the streamed
  `system/init` (and from later messages). Continuation turns reuse the captured
  id via `--resume <session_id>` so the conversation thread persists across
  turns.

  Public API mirrors the upstream `SymphonyElixir.Codex.AppServer` so the rest
  of Symphony — `AgentRunner`, `Orchestrator`, the dashboard — needs no
  protocol-aware changes. Emitted runtime events match the spec §10.4 set the
  orchestrator integrates (`session_started`, `turn_completed`, `turn_failed`,
  `turn_ended_with_error`, `notification`, `other_message`, `malformed`,
  `startup_failed`).

  Trust posture: the default `permission_mode` is `bypassPermissions`,
  matching the high-trust example in spec §10.5. Operators who need stricter
  posture should set `claude_code.permission_mode` in `WORKFLOW.md` to
  `acceptEdits`, `plan`, or `default`.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety, SSH}

  @port_line_bytes 10 * 1024 * 1024
  @max_stream_log_bytes 1_000

  @type session :: %{
          required(:agent_pid) => pid(),
          required(:workspace) => Path.t(),
          required(:worker_host) => String.t() | nil,
          required(:runtime) => map()
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, runtime} <- Config.claude_code_runtime_settings(expanded_workspace) do
      {:ok, agent_pid} =
        Elixir.Agent.start_link(fn -> %{thread_id: nil, turn_count: 0} end)

      {:ok,
       %{
         agent_pid: agent_pid,
         workspace: expanded_workspace,
         worker_host: worker_host,
         runtime: runtime
       }}
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []) when is_binary(prompt) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    {thread_id, turn_index} = next_turn_state(session.agent_pid)

    case open_turn_port(session, prompt, thread_id) do
      {:ok, port} ->
        metadata = port_metadata(port, session.worker_host)

        case stream_turn(port, on_message, metadata, session, thread_id, turn_index, issue) do
          {:ok, result} ->
            commit_turn_state(session.agent_pid, result.thread_id, turn_index)

            Logger.info(
              "Claude Code session completed for #{issue_context(issue)} session_id=#{result.session_id}"
            )

            {:ok, result}

          {:error, reason} ->
            Logger.warning(
              "Claude Code session ended with error for #{issue_context(issue)}: #{inspect(reason)}"
            )

            emit_message(
              on_message,
              :turn_ended_with_error,
              %{
                session_id: session_id_for_failure(thread_id, turn_index),
                reason: reason
              },
              metadata
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Claude Code session failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, %{})
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{agent_pid: pid}) when is_pid(pid) do
    if Process.alive?(pid), do: Elixir.Agent.stop(pid, :normal, 1_000)
    :ok
  end

  def stop_session(_), do: :ok

  ## Internals

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp next_turn_state(agent_pid) do
    Elixir.Agent.get(agent_pid, fn %{thread_id: thread_id, turn_count: count} ->
      {thread_id, count + 1}
    end)
  end

  defp commit_turn_state(agent_pid, thread_id, turn_index) when is_pid(agent_pid) do
    Elixir.Agent.update(agent_pid, fn _ ->
      %{thread_id: thread_id, turn_count: turn_index}
    end)
  end

  defp open_turn_port(session, prompt, thread_id) do
    shell_command = build_shell_command(session.runtime, thread_id, prompt)
    open_port(session.workspace, session.worker_host, shell_command)
  end

  defp open_port(workspace, nil, shell_command) do
    case System.find_executable("bash") do
      nil ->
        {:error, :bash_not_found}

      executable ->
        port =
          Port.open(
            {:spawn_executable, String.to_charlist(executable)},
            [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              args: [~c"-lc", String.to_charlist(shell_command)],
              cd: String.to_charlist(workspace),
              line: @port_line_bytes
            ]
          )

        {:ok, port}
    end
  end

  defp open_port(workspace, worker_host, shell_command) when is_binary(worker_host) do
    remote_command =
      Enum.join(
        [
          "cd " <> shell_escape(workspace),
          shell_command
        ],
        " && "
      )

    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp build_shell_command(runtime, thread_id, prompt) do
    sentinel = "__SYMPHONY_CC_PROMPT_#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}__"

    args =
      [runtime.command]
      |> append_args(["--print", "--output-format", "stream-json", "--verbose"])
      |> append_args(["--permission-mode", runtime.permission_mode])
      |> append_args(model_args(runtime.model))
      |> append_args(resume_args(thread_id))
      |> append_args(runtime.extra_args || [])

    cli_invocation = Enum.join(args, " ")

    """
    exec #{cli_invocation} <<'#{sentinel}'
    #{prompt}
    #{sentinel}
    """
    |> String.trim_trailing()
  end

  defp append_args(args, []), do: args
  defp append_args(args, more), do: args ++ more

  defp model_args(nil), do: []
  defp model_args(""), do: []
  defp model_args(model) when is_binary(model), do: ["--model", model]

  defp resume_args(nil), do: []
  defp resume_args(""), do: []
  defp resume_args(thread_id) when is_binary(thread_id), do: ["--resume", thread_id]

  defp port_metadata(port, worker_host) when is_port(port) do
    base =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} -> %{codex_app_server_pid: to_string(os_pid)}
        _ -> %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base, :worker_host, host)
      _ -> base
    end
  end

  defp port_metadata(_, _), do: %{}

  defp stream_turn(port, on_message, metadata, session, thread_id, turn_index, issue) do
    state = %{
      port: port,
      on_message: on_message,
      metadata: metadata,
      session: session,
      pending_thread_id: thread_id,
      turn_index: turn_index,
      issue: issue,
      pending_line: "",
      session_started_emitted: false,
      timeout_ms: session.runtime.turn_timeout_ms
    }

    receive_loop(state)
  end

  defp receive_loop(%{port: port, timeout_ms: timeout_ms} = state) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = state.pending_line <> to_string(chunk)
        handle_line(%{state | pending_line: ""}, line)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(%{state | pending_line: state.pending_line <> to_string(chunk)})

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        stop_port(port)
        {:error, :turn_timeout}
    end
  end

  defp handle_line(state, line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "system"} = payload} ->
        handle_system(state, payload, line)

      {:ok, %{"type" => "result"} = payload} ->
        handle_result(state, payload, line)

      {:ok, %{"type" => "assistant"} = payload} ->
        emit_payload(state, :notification, payload, line)
        receive_loop(maybe_capture_session_id(state, payload))

      {:ok, %{"type" => "user"} = payload} ->
        emit_payload(state, :notification, payload, line)
        receive_loop(maybe_capture_session_id(state, payload))

      {:ok, payload} when is_map(payload) ->
        emit_payload(state, :other_message, payload, line)
        receive_loop(maybe_capture_session_id(state, payload))

      {:ok, payload} ->
        emit_payload(state, :other_message, %{value: payload}, line)
        receive_loop(state)

      {:error, _reason} ->
        log_non_json_stream_line(line, "turn stream")

        if protocol_message_candidate?(line) do
          emit_message(
            state.on_message,
            :malformed,
            %{payload: line, raw: line},
            state.metadata
          )
        end

        receive_loop(state)
    end
  end

  defp handle_system(state, %{"subtype" => "init"} = payload, raw_line) do
    state = maybe_capture_session_id(state, payload)
    emit_session_started_once(state, raw_line)
    receive_loop(%{state | session_started_emitted: true})
  end

  defp handle_system(state, payload, raw_line) do
    emit_payload(state, :notification, payload, raw_line)
    receive_loop(maybe_capture_session_id(state, payload))
  end

  defp handle_result(state, payload, raw_line) do
    state = maybe_capture_session_id(state, payload)
    state = ensure_session_started_emitted(state, raw_line)
    thread_id = state.pending_thread_id || generated_session_id(payload)
    session_id = compose_session_id(thread_id, state.turn_index)

    case classify_result(payload) do
      :success ->
        emit_message(
          state.on_message,
          :turn_completed,
          %{
            payload: enrich_payload_usage(payload),
            raw: raw_line,
            details: payload,
            session_id: session_id,
            usage: enrich_usage(Map.get(payload, "usage")),
            cost_usd: Map.get(payload, "total_cost_usd"),
            duration_ms: Map.get(payload, "duration_ms"),
            num_turns: Map.get(payload, "num_turns")
          },
          state.metadata
        )

        {:ok,
         %{
           result: payload,
           session_id: session_id,
           thread_id: thread_id,
           turn_id: Integer.to_string(state.turn_index)
         }}

      {:failure, reason} ->
        emit_message(
          state.on_message,
          :turn_failed,
          %{
            payload: enrich_payload_usage(payload),
            raw: raw_line,
            details: payload,
            session_id: session_id,
            reason: reason
          },
          state.metadata
        )

        {:error, {:turn_failed, payload}}
    end
  end

  defp classify_result(%{"is_error" => true} = payload) do
    {:failure, Map.get(payload, "subtype") || "unknown"}
  end

  defp classify_result(%{"subtype" => "success"}), do: :success
  defp classify_result(%{"subtype" => subtype}) when is_binary(subtype), do: {:failure, subtype}
  defp classify_result(_), do: :success

  defp emit_session_started_once(%{session_started_emitted: true}, _raw_line), do: :ok

  defp emit_session_started_once(state, raw_line) do
    thread_id = state.pending_thread_id

    if is_binary(thread_id) do
      session_id = compose_session_id(thread_id, state.turn_index)

      emit_message(
        state.on_message,
        :session_started,
        %{
          session_id: session_id,
          thread_id: thread_id,
          turn_id: Integer.to_string(state.turn_index),
          raw: raw_line
        },
        state.metadata
      )
    end

    :ok
  end

  defp ensure_session_started_emitted(%{session_started_emitted: true} = state, _raw_line),
    do: state

  defp ensure_session_started_emitted(state, raw_line) do
    emit_session_started_once(state, raw_line)
    %{state | session_started_emitted: true}
  end

  defp maybe_capture_session_id(%{pending_thread_id: existing} = state, _)
       when is_binary(existing) and existing != "" do
    state
  end

  defp maybe_capture_session_id(state, payload) do
    case extract_session_id(payload) do
      id when is_binary(id) and id != "" -> %{state | pending_thread_id: id}
      _ -> state
    end
  end

  defp extract_session_id(%{"session_id" => id}) when is_binary(id), do: id
  defp extract_session_id(_), do: nil

  defp generated_session_id(payload) do
    case extract_session_id(payload) do
      id when is_binary(id) -> id
      _ -> "unknown"
    end
  end

  defp compose_session_id(thread_id, turn_index) when is_binary(thread_id) and is_integer(turn_index) do
    "#{thread_id}-#{turn_index}"
  end

  defp session_id_for_failure(nil, turn_index), do: "unknown-#{turn_index}"

  defp session_id_for_failure(thread_id, turn_index) when is_binary(thread_id) do
    "#{thread_id}-#{turn_index}"
  end

  defp emit_payload(state, event, payload, raw_line) do
    metadata = state.metadata |> Map.merge(usage_metadata(payload))

    emit_message(
      state.on_message,
      event,
      %{payload: payload, raw: raw_line},
      metadata
    )
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message =
      metadata
      |> Map.merge(details)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  defp usage_metadata(payload) do
    cond do
      usage = top_level_usage(payload) -> %{usage: enrich_usage(usage)}
      assistant_usage = assistant_message_usage(payload) -> %{usage: enrich_usage(assistant_usage)}
      true -> %{}
    end
  end

  defp top_level_usage(payload) when is_map(payload) do
    case Map.get(payload, "usage") do
      %{} = usage -> usage
      _ -> nil
    end
  end

  defp top_level_usage(_), do: nil

  defp assistant_message_usage(%{"type" => "assistant", "message" => %{"usage" => %{} = usage}}),
    do: usage

  defp assistant_message_usage(_), do: nil

  # Claude usage maps don't include a single `total_tokens`; the orchestrator
  # token integration looks for one. Synthesize it from the components Anthropic
  # reports so token totals roll up correctly.
  defp enrich_usage(usage) when is_map(usage) do
    inputs = integer_or_zero(usage, "input_tokens")
    outputs = integer_or_zero(usage, "output_tokens")
    cache_creation = integer_or_zero(usage, "cache_creation_input_tokens")
    cache_read = integer_or_zero(usage, "cache_read_input_tokens")

    Map.put(usage, "total_tokens", inputs + outputs + cache_creation + cache_read)
  end

  defp enrich_usage(other), do: other

  defp enrich_payload_usage(%{"usage" => usage} = payload) when is_map(usage) do
    Map.put(payload, "usage", enrich_usage(usage))
  end

  defp enrich_payload_usage(payload), do: payload

  defp integer_or_zero(map, key) do
    case Map.get(map, key) do
      v when is_integer(v) and v >= 0 -> v
      _ -> 0
    end
  end

  defp log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Claude Code #{stream_label} output: #{text}")
      else
        Logger.debug("Claude Code #{stream_label} output: #{text}")
      end
    end
  end

  defp protocol_message_candidate?(data) do
    data
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?("{")
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError -> :ok
        end
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_message(_message), do: :ok
end

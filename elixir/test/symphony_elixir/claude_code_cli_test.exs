defmodule SymphonyElixir.ClaudeCode.CLITest do
  use SymphonyElixir.TestSupport

  @moduletag :claude_code_cli

  describe "workspace cwd guard" do
    test "rejects workspace root and paths outside workspace root" do
      test_root = scratch_root("cwd-guard")

      try do
        workspace_root = Path.join(test_root, "workspaces")
        outside_workspace = Path.join(test_root, "outside")

        File.mkdir_p!(workspace_root)
        File.mkdir_p!(outside_workspace)

        write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

        issue = sample_issue("MT-999")

        assert {:error, {:invalid_workspace_cwd, :workspace_root, _path}} =
                 AppServer.run(workspace_root, "guard", issue)

        assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
                 AppServer.run(outside_workspace, "guard", issue)
      after
        File.rm_rf(test_root)
      end
    end

    test "rejects symlink escapes that point outside the workspace root" do
      test_root = scratch_root("symlink-cwd-guard")

      try do
        workspace_root = Path.join(test_root, "workspaces")
        outside_workspace = Path.join(test_root, "outside")
        symlink_workspace = Path.join(workspace_root, "MT-1000")

        File.mkdir_p!(workspace_root)
        File.mkdir_p!(outside_workspace)
        File.ln_s!(outside_workspace, symlink_workspace)

        write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

        issue = sample_issue("MT-1000")

        assert {:error, {:invalid_workspace_cwd, :symlink_escape, ^symlink_workspace, _root}} =
                 AppServer.run(symlink_workspace, "guard", issue)
      after
        File.rm_rf(test_root)
      end
    end
  end

  describe "headless turn lifecycle" do
    test "captures session_id from stream-json init and emits session_started + turn_completed" do
      with_fake_claude_run(success_stream(), fn ctx ->
        events = collect_events(ctx)

        assert Enum.find(events, fn ev ->
                 ev.event == :session_started and ev.thread_id == "session-abc-123"
               end),
               "expected session_started carrying thread_id from system/init"

        assert Enum.find(events, fn ev -> ev.event == :turn_completed end),
               "expected turn_completed at end of stream"

        assert {:ok, result} = ctx.return_value
        assert result.thread_id == "session-abc-123"
        assert result.turn_id == "1"
        assert result.session_id == "session-abc-123-1"
      end)
    end

    test "synthesizes total_tokens from Claude usage components" do
      with_fake_claude_run(success_stream(), fn ctx ->
        events = collect_events(ctx)
        completed = Enum.find(events, &(&1.event == :turn_completed))

        assert is_map(completed)
        usage = completed.usage
        # input + output + cache_creation + cache_read = 12 + 34 + 5 + 6 = 57
        assert usage["total_tokens"] == 57
        assert usage["input_tokens"] == 12
        assert usage["output_tokens"] == 34
      end)
    end

    test "exposes usage at a path the orchestrator's token extractor knows" do
      # Symphony's orchestrator only follows Codex-specific paths when
      # extracting deltas. The adapter must wrap Anthropic usage at one of
      # those paths or the running-entry token totals stay 0.
      with_fake_claude_run(success_stream(), fn ctx ->
        events = collect_events(ctx)

        notification =
          Enum.find(events, fn ev ->
            ev.event == :notification and is_map(Map.get(ev, "tokenUsage"))
          end)

        assert notification, "expected a notification carrying tokenUsage metadata"
        flat = get_in(notification, ["tokenUsage", "total"])
        assert is_map(flat)
        assert flat["input_tokens"] == 12
        assert flat["output_tokens"] == 34
        assert flat["total_tokens"] == 57
      end)
    end

    test "treats is_error result as a turn failure" do
      with_fake_claude_run(error_stream(), fn ctx ->
        assert {:error, {:turn_failed, _payload}} = ctx.return_value

        events = collect_events(ctx)
        assert Enum.find(events, &(&1.event == :turn_failed))
      end)
    end

    test "uses --resume on the second turn after a successful first turn" do
      with_fake_claude_run([success_stream(), success_stream(thread_id: "session-abc-123")], fn ctx ->
        # First turn (no --resume in argv).
        first_argv = read_argv_trace(ctx, 0)
        refute Enum.member?(first_argv, "--resume"),
               "first turn should not pass --resume; got: #{inspect(first_argv)}"

        # Second turn must resume the captured thread_id.
        second_argv = read_argv_trace(ctx, 1)
        assert "--resume" in second_argv
        assert Enum.member?(second_argv, "session-abc-123"),
               "second turn argv missing captured session_id: #{inspect(second_argv)}"
      end,
      turn_count: 2)
    end

    test "respects configured permission_mode" do
      with_fake_claude_run(success_stream(), fn ctx ->
        argv = read_argv_trace(ctx, 0)
        assert "--permission-mode" in argv
        # Default test config sets bypassPermissions.
        assert "bypassPermissions" in argv
      end)
    end
  end

  ## Helpers

  defp scratch_root(label) do
    Path.join(
      System.tmp_dir!(),
      "symphony-cc-#{label}-#{System.unique_integer([:positive])}"
    )
  end

  defp sample_issue(identifier) do
    %Issue{
      id: "issue-#{identifier}",
      identifier: identifier,
      title: "Sample issue #{identifier}",
      description: "Generated for Claude Code CLI test",
      state: "In Progress",
      url: "https://example.org/issues/#{identifier}",
      labels: ["test"]
    }
  end

  defp success_stream(opts \\ []) do
    thread_id = Keyword.get(opts, :thread_id, "session-abc-123")

    [
      ~s|{"type":"system","subtype":"init","cwd":"<cwd>","session_id":"#{thread_id}","tools":[],"model":"claude-opus-4-7","permissionMode":"bypassPermissions"}|,
      ~s|{"type":"assistant","session_id":"#{thread_id}","message":{"id":"msg_1","role":"assistant","model":"claude-opus-4-7","content":[{"type":"text","text":"working"}],"usage":{"input_tokens":12,"output_tokens":34,"cache_creation_input_tokens":5,"cache_read_input_tokens":6}}}|,
      ~s|{"type":"result","subtype":"success","is_error":false,"duration_ms":1500,"duration_api_ms":1200,"num_turns":1,"result":"done","session_id":"#{thread_id}","total_cost_usd":0.012,"usage":{"input_tokens":12,"output_tokens":34,"cache_creation_input_tokens":5,"cache_read_input_tokens":6}}|
    ]
  end

  defp error_stream do
    [
      ~s|{"type":"system","subtype":"init","cwd":"<cwd>","session_id":"session-err-1","tools":[],"model":"claude-opus-4-7","permissionMode":"bypassPermissions"}|,
      ~s|{"type":"result","subtype":"error_during_execution","is_error":true,"duration_ms":500,"session_id":"session-err-1","usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}|
    ]
  end

  # Spins up an isolated workspace, writes a fake `claude` shell script that
  # emits the configured stream-json lines, then drives one or more turns.
  defp with_fake_claude_run(streams, assertion, opts \\ [])

  defp with_fake_claude_run(streams, assertion, opts) when is_list(streams) and is_list(hd(streams)) do
    do_with_fake_claude_run(streams, assertion, opts)
  end

  defp with_fake_claude_run(stream, assertion, opts) do
    do_with_fake_claude_run([stream], assertion, opts)
  end

  defp do_with_fake_claude_run(streams, assertion, opts) do
    test_root = scratch_root("fake-claude")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-EXEC")
    fake_claude = Path.join(test_root, "fake-claude")
    argv_trace = Path.join(test_root, "argv.trace")
    counter_file = Path.join(test_root, "counter")

    File.mkdir_p!(workspace)
    File.write!(counter_file, "0")

    File.write!(fake_claude, fake_claude_script(streams, argv_trace, counter_file))
    File.chmod!(fake_claude, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      claude_code_command: fake_claude
    )

    issue = sample_issue("MT-EXEC")

    test_pid = self()

    on_message = fn msg ->
      send(test_pid, {:cc_event, msg})
      :ok
    end

    turn_count = Keyword.get(opts, :turn_count, 1)

    return_value =
      try do
        case AppServer.start_session(workspace) do
          {:ok, session} ->
            try do
              run_turns(session, issue, on_message, turn_count)
            after
              AppServer.stop_session(session)
            end

          other ->
            other
        end
      rescue
        e -> {:error, {:exception, e}}
      end

    ctx = %{
      test_root: test_root,
      workspace: workspace,
      argv_trace: argv_trace,
      return_value: return_value
    }

    try do
      assertion.(ctx)
    after
      File.rm_rf(test_root)
    end
  end

  defp run_turns(session, issue, on_message, 1) do
    AppServer.run_turn(session, "first prompt", issue, on_message: on_message)
  end

  defp run_turns(session, issue, on_message, n) when n > 1 do
    Enum.reduce(1..n, :ok, fn turn, _acc ->
      AppServer.run_turn(session, "prompt #{turn}", issue, on_message: on_message)
    end)
  end

  defp collect_events(_ctx) do
    drain_events([])
  end

  defp drain_events(acc) do
    receive do
      {:cc_event, msg} -> drain_events([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp read_argv_trace(ctx, turn_index) do
    case File.read(ctx.argv_trace) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.at(turn_index, "")
        |> String.split("\t", trim: true)

      _ ->
        []
    end
  end

  # The fake claude script reads argv, appends to argv.trace, picks the next
  # stream from the supplied list (one stream per turn), and emits each line.
  defp fake_claude_script(streams, argv_trace, counter_file) do
    streams_block =
      streams
      |> Enum.with_index()
      |> Enum.map(fn {lines, idx} ->
        case_block(idx, lines)
      end)
      |> Enum.join("\n")

    """
    #!/usr/bin/env bash
    set -e

    # Record argv (tab-separated) for each invocation on its own line.
    argv_line=""
    for arg in "$@"; do
      argv_line+="$arg"$'\\t'
    done
    printf "%s\\n" "$argv_line" >> #{shell_quote(argv_trace)}

    # Read prompt heredoc but ignore it.
    cat > /dev/null

    # Pick the stream for this turn based on counter_file.
    counter=$(cat #{shell_quote(counter_file)})
    next=$((counter + 1))
    printf "%s" "$next" > #{shell_quote(counter_file)}

    case "$counter" in
    #{streams_block}
    *)
      printf '{"type":"result","subtype":"success","is_error":false,"session_id":"unused","duration_ms":0,"num_turns":1,"result":"","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}\\n'
      ;;
    esac
    """
  end

  defp case_block(idx, lines) do
    body =
      lines
      |> Enum.map(fn line ->
        # Each line is a JSON literal; bash printf %s + \n.
        ~s|      printf '%s\\n' #{shell_quote(line)}|
      end)
      |> Enum.join("\n")

    """
        #{idx})
    #{body}
          ;;
    """
  end

  defp shell_quote(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end

extension CodingPlanUITests {
    static let acpClient = #"""
    import json, pathlib, subprocess, sys, time, uuid

    def emit(payload):
        print(json.dumps(dict(jsonrpc="2.0", **payload)), flush=True)

    def ask_user(servers):
        server = next(item for item in servers if item["name"] == "rxcode-ide")
        with subprocess.Popen([server["command"], *server["args"]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as bridge:
            def rpc(i, method, params):
                bridge.stdin.write(json.dumps(dict(jsonrpc="2.0", id=i, method=method, params=params)) + "\n")
                bridge.stdin.flush()
                return json.loads(bridge.stdout.readline())
            try:
                rpc(1, "initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "fixture", "version": "1"}})
                tools = rpc(2, "tools/list", {})["result"]["tools"]
                assert [tool["name"] for tool in tools] == ["ide__ask_user"]
                assert "error" in rpc(3, "tools/call", {"name": "ide__get_projects", "arguments": {}})
                result = rpc(4, "tools/call", {"name": "ide__ask_user", "arguments": {
                    "question": "How many backups should be kept?", "options": ["One copy", "Two copies"]}})
                return result["result"]["content"][0]["text"]
            finally:
                bridge.stdin.close()

    for line in sys.stdin:
        call = json.loads(line)
        method = call.get("method")
        if method == "initialize":
            result = {"protocolVersion": 1, "agentCapabilities": {}}
        elif method == "session/new":
            servers = call["params"]["mcpServers"]
            result = {"sessionId": str(uuid.uuid4())}
        elif method == "session/prompt":
            params = call["params"]
            prompt = params["prompt"][0]["text"]
            if "Distill the requested work" in prompt:
                name = "Test story" if "project story with" in prompt else "Test task"
                answer = name + "\n\nSave settings and verify reopening."
            elif "Plan backup retention." in prompt:
                if "You are reviewer 1." in prompt:
                    assert ask_user(servers) == "User answered: Two copies"
                    answer = "Verified the retention choice with the user."
                elif "You are the host." in prompt:
                    assert "How many backups should be kept?\n\nTwo copies" in prompt
                    assert "Verified the retention choice with the user." in prompt
                    answer = "Keep two backup copies."
                else:
                    answer = "Review the retention period."
            elif "You are hosting" in prompt:
                answer = "Review storage and reopening."
            elif "As host, reply to the user's latest messages" in prompt:
                pathlib.Path(sys.argv[1]).with_name("reply-prompt").write_text(prompt)
                answer = "A backup lets you recover settings." if "Why keep a backup?" in prompt and "Keep a local backup." in prompt else "Missing context."
            elif "You are reviewer 1." in prompt:
                answer = "<!-- Protect writes. -->\n```suggestion\nSave settings.\n---\nSave settings atomically.\n```"
            elif "You are reviewer 2." in prompt:
                pathlib.Path(sys.argv[1]).with_name("reviewer-2-prompt").write_text(prompt)
                answer = "The acceptance check covers reopening."
            elif "You are the host." in prompt:
                answer = "## Implementation\n\nSave settings atomically and verify reopening."
            elif "Return the plan itself" in prompt:
                pathlib.Path(sys.argv[1]).with_name("draft-prompt").write_text(prompt)
                emit({"method": "session/update", "params": {"sessionId": params["sessionId"],
                      "update": {"sessionUpdate": "tool_call", "toolCallId": "read-brief", "kind": "read",
                                 "title": "Read requirements", "status": "in_progress", "rawInput": {"path": "Plan requirements.md"}}}})
                emit({"method": "session/update", "params": {"sessionId": params["sessionId"],
                      "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "## Implementation\n\nPersist stable keys.\n\n"}}}})
                deadline = time.monotonic() + 90
                while not pathlib.Path(sys.argv[1]).exists() and time.monotonic() < deadline:
                    time.sleep(0.05)
                emit({"method": "session/update", "params": {"sessionId": params["sessionId"],
                      "update": {"sessionUpdate": "tool_call_update", "toolCallId": "read-brief",
                                 "status": "completed", "rawOutput": "Support reopening."}}})
                answer = "Save settings."
            else:
                answer = "Implementation complete."
            emit({"method": "session/update", "params": {"sessionId": params["sessionId"],
                  "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": answer}}}})
            result = {"stopReason": "end_turn"}
        else:
            result = {}
        if "id" in call:
            emit({"id": call["id"], "result": result})
    """#
}

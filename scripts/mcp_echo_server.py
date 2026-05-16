#!/usr/bin/env python3
import json
import sys


def send(payload):
    sys.stdout.write(json.dumps(payload, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def result(request_id, value):
    send({"jsonrpc": "2.0", "id": request_id, "result": value})


def error(request_id, code, message):
    send({
        "jsonrpc": "2.0",
        "id": request_id,
        "error": {"code": code, "message": message},
    })


for line in sys.stdin:
    try:
        frame = json.loads(line)
    except json.JSONDecodeError:
        continue

    method = frame.get("method")
    request_id = frame.get("id")
    params = frame.get("params") or {}

    if request_id is None:
        continue

    if method == "initialize":
        result(request_id, {
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "rxcode-ui-test-mcp", "version": "1.0.0"},
        })
    elif method == "tools/list":
        result(request_id, {
            "tools": [{
                "name": "rxcode_test_echo",
                "description": "Return the input text for RxCode UI acceptance tests.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "text": {"type": "string"},
                    },
                    "required": ["text"],
                },
            }],
        })
    elif method == "tools/call":
        name = params.get("name")
        arguments = params.get("arguments") or {}
        if name != "rxcode_test_echo":
            error(request_id, -32601, f"unknown tool: {name}")
            continue
        text = arguments.get("text", "")
        result(request_id, {
            "content": [{"type": "text", "text": f"rxcode-mcp-echo:{text}"}],
            "isError": False,
        })
    else:
        result(request_id, {})

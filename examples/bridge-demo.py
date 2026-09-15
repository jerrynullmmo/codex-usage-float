#!/usr/bin/env python3
"""Print synthetic bridge data. No app access, network, configuration writes or model calls."""
import datetime
import json

now = datetime.datetime.now(datetime.timezone.utc).isoformat()
print(json.dumps({
    "schemaVersion": 1,
    "id": "synthetic-example",
    "name": "合成示例（非真实用量）",
    "bundleIDs": ["org.example.desktop"],
    "processNames": ["ExampleDesktop.exe"],
    "updatedAt": now,
    "activeSessionID": "example-root",
    "childrenComplete": True,
    "sessions": [
        {"id": "example-root", "title": "合成主任务", "total": {"input": 1000, "output": 100},
         "round": {"input": 300, "output": 30}, "roundStartedAt": now},
        {"id": "example-child", "title": "合成子代理", "parentID": "example-root",
         "total": {"input": 500, "output": 50}, "round": {"input": 200, "output": 20}, "roundStartedAt": now},
    ],
}, ensure_ascii=False, indent=2))

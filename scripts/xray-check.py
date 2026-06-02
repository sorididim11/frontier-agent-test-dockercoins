#!/usr/bin/env python3
"""Check X-Ray trace segment details for a given trace ID."""
import json
import os
import subprocess
import sys

AWS_PROFILE = os.environ.get("AWS_PROFILE", "member1-acc")
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")

TRACE_ID = sys.argv[1] if len(sys.argv) > 1 else "1-69ae98c3-ee3e1570212b745dd53a38e1"

result = subprocess.run([
    "aws", "xray", "batch-get-traces",
    "--trace-ids", TRACE_ID,
    "--profile", AWS_PROFILE, "--region", AWS_REGION, "--no-cli-pager",
], capture_output=True, text=True)

data = json.loads(result.stdout)
for trace in data.get("Traces", []):
    for seg in trace.get("Segments", []):
        doc = json.loads(seg["Document"])
        name = doc.get("name", "?")
        fault = doc.get("fault", False)
        error = doc.get("error", False)
        cause = doc.get("cause", {})
        http_resp = doc.get("http", {}).get("response", {})
        metadata = doc.get("metadata", {})
        print(f"=== Segment: {name} ===")
        print(f"  fault={fault}, error={error}, http={http_resp}")
        if cause:
            for e in cause.get("exceptions", [])[:3]:
                print(f"  exception: type={e.get('type')}, msg={e.get('message','')[:150]}")
        if metadata:
            for ns, vals in metadata.items():
                print(f"  metadata[{ns}]: {json.dumps(vals, default=str)[:200]}")
        for sub in doc.get("subsegments", [])[:8]:
            sname = sub.get("name", "?")
            sfault = sub.get("fault", False)
            serror = sub.get("error", False)
            shttp = sub.get("http", {}).get("response", {})
            scause = sub.get("cause", {})
            print(f"  subseg: {sname} fault={sfault} error={serror} http={shttp}")
            if scause:
                for e in scause.get("exceptions", [])[:2]:
                    print(f"    exc: type={e.get('type')}, msg={e.get('message','')[:150]}")
            for ss in sub.get("subsegments", [])[:5]:
                ssname = ss.get("name", "?")
                ssfault = ss.get("fault", False)
                sscause = ss.get("cause", {})
                print(f"    subsub: {ssname} fault={ssfault}")
                if sscause:
                    for e in sscause.get("exceptions", [])[:2]:
                        print(f"      exc: type={e.get('type')}, msg={e.get('message','')[:150]}")

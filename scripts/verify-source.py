"""Verify exported Solidity bytes against the published SHA-256 manifest."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / "deployments/source-manifest.json").read_text(encoding="utf-8"))
failed = []
for entry in manifest["files"]:
    file = (root / entry["file"]).resolve()
    if not file.is_relative_to(root) or not file.is_file():
        failed.append(entry["file"])
        continue
    actual = hashlib.sha256(file.read_bytes()).hexdigest()
    if actual != entry["sha256"]:
        failed.append(entry["file"])
if failed:
    raise SystemExit("Source verification failed: " + ", ".join(failed))
print(f"Verified {len(manifest['files'])} Solidity source/test files.")

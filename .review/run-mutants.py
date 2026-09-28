import argparse
import hashlib
import os
from pathlib import Path
import re
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("--logs", type=Path, required=True)
parser.add_argument("patches", nargs="+", type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
args.logs.mkdir(parents=True, exist_ok=True)
environment = os.environ.copy()
environment["CLANG_MODULE_CACHE_PATH"] = str(root / ".review/clang-cache")
for key in ("OPENROUTER_API_KEY", "INTERVALS_API_KEY"):
    environment.pop(key, None)

def git(*arguments):
    subprocess.run(["git", *arguments], cwd=root, check=True)

def digest(path):
    return hashlib.sha256((root / path).read_bytes()).hexdigest()

with (args.logs / "mutants.tsv").open("w") as table:
    table.write("mutant\tresult\texit\tseconds\tkilling_tests\tlog\n")
    for patch in args.patches:
        paths = re.findall(r"^\+\+\+ b/(.+)$", patch.read_text(), re.MULTILINE)
        before = {path: digest(path) for path in paths}
        git("apply", "--check", str(patch))
        git("apply", str(patch))
        started = time.monotonic()
        log = args.logs / (patch.stem + ".log")
        try:
            with log.open("w") as output:
                result = subprocess.run(
                    ["pnpm", "test:swift", "--disable-sandbox"], cwd=root, env=environment,
                    stdout=output, stderr=subprocess.STDOUT, timeout=600,
                )
        finally:
            git("apply", "-R", str(patch))
            if any(digest(path) != checksum for path, checksum in before.items()):
                raise RuntimeError("Mutation reversal did not restore the production sources")
        output = log.read_text()
        killed = sorted(set(re.findall(r"✘ Test (\w+)\([^\n]*? recorded an issue", output)))
        completed = "Test run with" in output
        status = "KILLED" if result.returncode and killed and completed else (
            "SURVIVED" if result.returncode == 0 else "INVALID"
        )
        table.write(
            f"{patch.stem}\t{status}\t{result.returncode}\t{time.monotonic() - started:.1f}"
            f"\t{','.join(killed)}\t{log}\n"
        )
        table.flush()
        print(f"{patch.stem}: {status}, source restored", flush=True)
        if status != "KILLED":
            raise RuntimeError(f"{patch.stem}: {status}; inspect {log}")

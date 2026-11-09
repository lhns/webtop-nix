"""split-layers.py on a small synthetic closure: assignment order, scopes, layer order, the graft
check and the config ceiling. Run: python3 tests/split-layers-test.py"""
import json
import os
import subprocess
import sys
import tempfile

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "image", "split-layers.py")
MiB = 1 << 20


def p(n):
    return f"/nix/store/{n[0] * 32}-{n}"


def run(graph, spec, reference=None):
    with tempfile.TemporaryDirectory() as d:
        with open(f"{d}/reg", "w") as f:
            for path, (size, refs) in graph.items():
                f.write("\n".join([path, "sha256:x", str(size), "", str(len(refs))] + refs) + "\n")
        with open(f"{d}/spec", "w") as f:
            json.dump(spec, f)
        cmd = [sys.executable, SCRIPT, f"{d}/reg", f"{d}/spec", d]
        if reference is not None:
            with open(f"{d}/ref", "w") as f:
                f.write("\n".join(reference))
            cmd += ["--reference", f"{d}/ref"]
        r = subprocess.run(cmd, capture_output=True, text=True)
        layers = json.load(open(f"{d}/layers.json")) if r.returncode == 0 else None
        groups = json.load(open(f"{d}/groups.json")) if r.returncode == 0 else None
        return r, layers, groups


glibc, qt, kwin, ws, app, own, src, sp, etc, top = map(p, ["glibc", "qt", "kwin", "workspace", "app", "ownapp",
                                                           "source", "system-path", "etc", "toplevel"])
graph = {
    glibc: (MiB, []), qt: (MiB, [glibc]), kwin: (MiB, [qt]), ws: (MiB, [kwin, qt]), app: (MiB, [qt]),
    own: (MiB, [glibc]), src: (MiB, []), sp: (MiB, [ws, app, own]), etc: (MiB, [sp]), top: (MiB, [etc, sp, src]),
}
spec = {
    "groups": [
        {"name": "base", "anchors": [glibc]},
        {"name": "toolkits", "anchors": [qt]},
        {"name": "graft", "refsOf": ["name:system-path"], "dependentsOf": [kwin], "sameAsReference": True},
        {"name": "kde", "refsOf": [sp], "buckets": 2},
        {"name": "sources", "scope": "own", "anchors": [src]},
        {"name": "packages", "scope": "own", "refsOf": [sp]},
    ],
    "layerOrder": ["base", "toolkits", "kde", "graft", "sources", "packages"],
    "maxConfigMiB": 8,
}
ref = [glibc, qt, kwin, ws, app]

r, layers, groups = run(graph, spec, ref)
assert r.returncode == 0, r.stderr
where = {x: groups[i] for i, l in enumerate(layers) for x in l}
assert where[glibc] == "base" and where[qt] == "toolkits", where
assert where[kwin] == "graft" and where[ws] == "graft", where  # dependents of kwin among packages
assert where[app].startswith("kde"), where
assert where[own] == "packages" and where[src] == "sources", where  # not in the reference
assert {where[sp], where[etc], where[top]} == {"config"}, where
assert groups[-1] == "config" and groups.index("graft") > max(i for i, g in enumerate(groups) if g.startswith("kde"))
assert sorted(x for l in layers for x in l) == sorted(graph)

# Without a reference every path is the stack's: the own groups stay empty.
r, layers, groups = run(graph, spec)
assert r.returncode == 0 and "packages" not in groups and "sources" not in groups, (r.stderr, groups)

# A graft path the consumer rebuilt (same name, other hash) is reported and, with scope "any",
# still lands in the graft layer.
ws2 = "/nix/store/" + "z" * 32 + "-workspace"
spec_any = json.loads(json.dumps(spec))
spec_any["groups"][2]["scope"] = "any"
r, layers, groups = run(graph, spec_any, [glibc, qt, kwin, ws2, app])
where = {x: groups[i] for i, l in enumerate(layers) for x in l}
assert r.returncode == 0 and "differs from the reference image: workspace (via a build input)" in r.stdout, r.stdout
assert where[ws] == "graft", where

# The config ceiling.
big = dict(graph, **{etc: (20 * MiB, [sp])})
r, _, _ = run(big, spec, ref)
assert r.returncode == 1 and "config group is 22 MiB" in r.stderr, r.stderr
print("split-layers: ok")

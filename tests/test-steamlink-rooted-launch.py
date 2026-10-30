#!/usr/bin/env python3
"""Exercise the final installed descriptor with the real helper in a private root.

The root uses the installer's overlay, replacing only pf-launch with a harmless
probe. Required production Landlock policy is never weakened: older hosts report
an explicit enforcement gate, while capable kernels must execute the probe.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import tomllib

p = argparse.ArgumentParser()
for name in ("manifest", "layout", "inventory", "contract", "helper", "renderer"):
    p.add_argument("--" + name, required=True, type=Path)
a = p.parse_args()
manifest = tomllib.loads(a.manifest.read_text())
app_id = manifest["app"]["id"]
app_dir = Path("/opt/pocketforge/apps") / app_id
exec_path = app_dir / manifest["launch"]["exec"]
installed = a.layout / str(exec_path).lstrip("/")
assert installed.is_file() and os.access(installed, os.X_OK), installed
# The input is the final installed descriptor, including actual root/CAS digests.
assert manifest["runtime"]["root"]["digest"] != "sha256:" + "0" * 64
assert manifest["runtime"]["root"]["platform-runtime-version"] != "sha256:" + "0" * 64
xdg = {
    "XDG_CONFIG_HOME": f"/var/lib/pocketforge/apps/{app_id}/config",
    "XDG_STATE_HOME": f"/var/lib/pocketforge/apps/{app_id}/state",
    "XDG_CACHE_HOME": f"/var/cache/pocketforge/apps/{app_id}",
    "XDG_RUNTIME_DIR": f"/run/pf-app/{app_id}",
}
render = [str(a.renderer), "--manifest", str(a.manifest), "--platform-contract", str(a.contract),
          "--resource-inventory", str(a.inventory), "--app-dir", str(app_dir),
          "--platform-runtime", "/run/pocketforge/platform-runtime",
          "--xdg-config", xdg["XDG_CONFIG_HOME"], "--xdg-state", xdg["XDG_STATE_HOME"],
          "--xdg-cache", xdg["XDG_CACHE_HOME"], "--format", "json"]
policy = json.loads(subprocess.check_output(render, text=True))
probe = subprocess.run(["bwrap", "--unshare-all", "--ro-bind", "/", "/", "/bin/true"], capture_output=True)
if probe.returncode:
    raise SystemExit("rooted-launch=UNAVAILABLE reason=namespace_permission_required")
with tempfile.TemporaryDirectory(prefix="steamlink-rooted-launch-") as tmp:
    work = Path(tmp)
    root = work / "root"
    shutil.copytree(a.layout, root)
    def inside(path):
        return root / str(path).lstrip("/")
    def write(path, body):
        target = inside(path)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(body)
        return target
    shutil.copyfile(a.manifest, inside(app_dir / "app.toml"))
    executable = write(exec_path, '#!/bin/sh\nset -eu\n[ "$DISPLAY" = :0 ]\n[ -S /tmp/.X11-unix/X0 ]\n[ ! -e /run/pocketforge/x11/.X11-unix/X0 ]\nprintf "rooted-launch-exec=PASS DISPLAY=%s\\n" "$DISPLAY"\n')
    executable.chmod(0o755)
    sockets = []
    mappings = []
    # Construct ONLY destinations of the generated policy, never host X11 source.
    for mapping in policy["unit"]["bind_read_write_mappings"]:
        source = work / ("socket-" + str(len(sockets)))
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(str(source))
        sockets.append(listener)
        mappings += ["--bind", str(source), mapping["destination"]]
    environment_sources = {}
    readonly = []
    for env in policy["environment"]:
        source = work / ("environment-" + env["name"])
        source.write_text(f'{env["name"]}={env["expected_value"]}\n')
        environment_sources[env["source"]] = source
    for path in policy["unit"]["bind_read_only"]:
        source = environment_sources.get(path)
        if source is None:
            source = work / ("resource-" + str(len(readonly)))
            source.touch()
        readonly += ["--ro-bind", str(source), path]
    for path in policy["unit"]["bind_read_write"]:
        write(path, "")
    for path in [*xdg.values(), "/run/pocketforge/platform-runtime", "/etc", "/proc", "/dev"]:
        inside(path).mkdir(parents=True, exist_ok=True)
    # Host tools/libraries are fixture dependencies, not application policy grants.
    for path in ("/usr/lib", "/lib", "/lib64"):
        inside(path).mkdir(parents=True, exist_ok=True)
    write("/bin/sh", "")
    base = ["bwrap", "--unshare-all", "--ro-bind", str(root), "/"]
    for path in xdg.values():
        base += ["--bind", str(inside(path)), path]
    for path in ("/usr/lib", "/lib", "/lib64", "/bin/sh"):
        if Path(path).exists():
            base += ["--ro-bind", path, path]
    base += ["--proc", "/proc", "--dev", "/dev", "--ro-bind", str(a.helper), "/usr/bin/pf-app-launch",
             "--ro-bind", str(a.contract), "/usr/share/pocketforge/platform-capabilities.toml",
             "--ro-bind", str(a.inventory), f"/usr/share/pocketforge/app-policy/{app_id}.resources.json"]
    for key, value in xdg.items():
        base += ["--setenv", key, value]
    base += ["--setenv", "DISPLAY", ":99"]
    def run(extra=(), command=None, ro=readonly):
        return subprocess.run(base + ro + list(extra) + (command or ["/usr/bin/pf-app-launch", app_id]), text=True, capture_output=True)
    positive = run(mappings)
    if positive.returncode == 0:
        assert "rooted-launch-exec=PASS DISPLAY=:0" in positive.stdout, positive
        print("rooted-launch=PASS enforcement=production actual_exec=yes")
    else:
        assert positive.returncode == 77 and "reason=landlock_abi_too_old" in positive.stderr, positive
        # This proves harmless layout execution independently; it is NOT enforcement acceptance.
        layout = run(mappings + ["--setenv", "DISPLAY", ":0"], [str(exec_path)])
        assert layout.returncode == 0 and "rooted-launch-exec=PASS" in layout.stdout, layout
        print("rooted-launch=PARTIAL reason=landlock_abi_too_old production_exec=deferred layout_exec=PASS")
    def refused(label, extra=mappings):
        result = run(extra)
        assert result.returncode == 65 and "reason=policy_invalid" in result.stderr, (label, result)
        print(f"rooted-launch-negative={label} PASS")
    socket_path = inside("/tmp/.X11-unix/X0")
    socket_path.unlink()
    refused("missing-socket", [])
    socket_path.touch()
    refused("not-a-socket", [])
    socket_path.unlink()
    socket_path.symlink_to("X0-alias")
    refused("aliased-socket", [])
    socket_path.unlink()
    socket_path.touch()
    environment = environment_sources["/run/pocketforge/x11/policy/environment"]
    for bad in ("DISPLAY=:1\n", "DISPLAY=:0\nLD_PRELOAD=/evil\n", "DISPLAY=:0"):
        environment.write_text(bad)
        refused("malformed-environment")
    environment.write_text("DISPLAY=:0\n")
    env_path = "/run/pocketforge/x11/policy/environment"
    alias_target = write("/run/pocketforge/x11/policy/real-environment", "DISPLAY=:0\n")
    inside(env_path).unlink()
    inside(env_path).symlink_to(alias_target.name)
    without_env = [part for i in range(0, len(readonly), 3)
                   for part in (readonly[i:i + 3] if readonly[i + 2] != env_path else [])]
    aliased = run(mappings, ro=without_env)
    assert aliased.returncode == 65 and "reason=policy_invalid" in aliased.stderr, aliased
    print("rooted-launch-negative=aliased-environment PASS")
    inside(env_path).unlink()
    inside(env_path).touch()
    descriptor = inside(app_dir / "app.toml")
    descriptor.write_text(a.manifest.read_text().replace("[runtime.root]", "[runtime.root]\nunexpected = true"))
    invalid = run(mappings)
    assert invalid.returncode == 65 and "reason=descriptor_invalid" in invalid.stderr, invalid
    print("rooted-launch-negative=unknown-root-field PASS")
    for listener in sockets:
        listener.close()

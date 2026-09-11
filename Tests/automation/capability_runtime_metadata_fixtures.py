"""Synthetic closed runtime descriptors; no observations or qualification.

All paths, hashes and limits are invented fixture values. Nothing here supplies
runtime authority or performs file/process operations.
"""

def file_record(name, *, size=4096):
    return {"id": name, "identity": {
        "path": "/synthetic/runtime/" + name, "sha256": "1" * 64,
        "device": 1, "inode": 10 + sum(name.encode("ascii")), "size": size,
        "mode": 0o100755, "uid": 1, "gid": 1, "mtime_ns": 1, "ctime_ns": 1}}


def descriptors():
    files = [file_record(name) for name in sorted((
        "launcher", "main", "framework", "subprocess-source", "subprocess-cache",
        "extension", "extension-dependency"))]
    platform = {
        "schema_version": 1, "system": "Darwin", "architecture": "arm64",
        "product_version": "26.0", "build_version": "25A000",
        "apple_base": {
            "assumption": "selected-apple-system", "cache_uuid": "a" * 32,
            "images": [{"install_name": "/usr/lib/libSystem.B.dylib",
                        "uuid": "b" * 32, "file_type": 6}]}}
    runtime = {
        "schema_version": 1,
        "implementation": {"name": "cpython", "version": [3, 9, 6],
                           "pointer_bits": 64, "byteorder": "little",
                           "cache_tag": "cpython-39", "bytecode_magic": "11223344"},
        "startup": {"isolated": 1, "no_site": 1, "dont_write_bytecode": 1,
                    "ignore_environment": 1, "optimize": 0},
        "images": {
            "launcher": {"file": "launcher"},
            "main": {"file": "main", "uuid": "c" * 32, "file_type": 2,
                     "architecture": "arm64"},
            "framework": {"file": "framework", "uuid": "d" * 32,
                          "file_type": 6, "architecture": "arm64"}},
        "bindings": {
            "clock": {"module": "time", "name": "clock_gettime",
                      "constant": "CLOCK_UPTIME_RAW", "value": 8},
            "reset": {"module": "_signal", "name": "signal",
                      "getter_offset": 128, "wrapper_offset": 256,
                      "helper_offset": 384}},
        "files": files,
        "search_paths": ["/synthetic/runtime"],
        "absent_inputs": ["/synthetic/runtime/unused-cache"],
        "external_entry_module": "__main__",
        "modules": [
            {"name": "_signal", "kind": "builtin", "registry_name": "_signal",
             "spec_name": "_signal", "aliases": []},
            {"name": "importlib._bootstrap", "kind": "frozen",
             "registry_name": "_frozen_importlib", "spec_name": "_frozen_importlib",
             "aliases": ["_frozen_importlib"], "file_alias": None},
            {"name": "subprocess", "kind": "source", "spec_name": "subprocess",
             "aliases": [], "loader": "SourceFileLoader", "selected_input": "cache",
             "source": "subprocess-source", "cache": "subprocess-cache",
             "package_member": None},
            {"name": "synthetic_extension", "kind": "extension",
             "spec_name": "synthetic_extension", "aliases": [], "file": "extension",
             "uuid": "e" * 32, "dependencies": ["extension-dependency"]},
            {"name": "time", "kind": "builtin", "registry_name": "time",
             "spec_name": "time", "aliases": []}],
        "popen": {"module": "subprocess", "class": "Popen", "destructor": "__del__",
                  "source": "subprocess-source", "active_name": "_active",
                  "expected_active_count": 0},
        "limits": {"module_count": 16, "file_count": 16, "per_file_bytes": 8192,
                   "aggregate_file_bytes": 65536, "code_nodes": 256,
                   "code_depth": 16, "code_bytes": 65536,
                   "image_command_bytes": 65536}}
    return platform, runtime


def preload_descriptors():
    """Source-only synthetic selection with finite pre-load premises."""
    platform, runtime = descriptors()
    root = "/synthetic/runtime"
    runtime["files"] = [row for row in runtime["files"] if row["id"] != "subprocess-cache"]
    source = next(row for row in runtime["files"] if row["id"] == "subprocess-source")
    source["identity"]["path"] = root + "/subprocess.py"
    module = next(row for row in runtime["modules"] if row["name"] == "subprocess")
    module.update(selected_input="source", cache=None)
    cache = root + "/__pycache__/subprocess.cpython-39.pyc"
    legacy = root + "/subprocess.pyc"
    runtime["absent_inputs"] = sorted((cache, legacy, root + "/subprocess.so", root + "/extension.py"))
    preload = {"schema_version": 1, "policy": "stock-source-no-cache-v1",
        "launch_environment": {"LC_ALL": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
        "cache_branch": {"pycache_prefix": None, "check_hash_based_pycs": "default"},
        "directories": [
            {"path": path, "device": 1, "inode": 2, "mode": 0o40755,
             "uid": 1, "gid": 1, "mtime_ns": 1, "ctime_ns": 1}
            for path in (root, root + "/__pycache__")],
        "searches": [
            {"module": "subprocess", "candidates": [
                {"path": root + "/subprocess.so", "file": None},
                {"path": root + "/subprocess.py", "file": "subprocess-source"},
                {"path": cache, "file": None}, {"path": legacy, "file": None}]},
            {"module": "synthetic_extension", "candidates": [
                {"path": root + "/extension", "file": "extension"},
                {"path": root + "/extension.py", "file": None}]}]}
    return platform, runtime, preload

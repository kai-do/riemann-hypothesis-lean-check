"""Compare lean/ on disk against the archive itself (not against any manifest stored on disk).

Usage: python3 -I scripts/verify_from_archive.py <archive.tar.gz> <repo_root>

Reports files that are changed, missing, or added (outside lean/.lake). Exit 1 on any difference.
The caller must first check the archive against the committed ARCHIVE.sha256.
"""
import hashlib
import os
import sys
import tarfile


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    archive, root = sys.argv[1], sys.argv[2]
    expected = {}
    with tarfile.open(archive, "r:gz") as tf:
        for m in tf:
            if m.isfile():
                expected[m.name] = hashlib.sha256(tf.extractfile(m).read()).hexdigest()

    changed, missing = [], []
    for name, digest in expected.items():
        path = os.path.join(root, name)
        if not os.path.isfile(path):
            missing.append(name)
        elif sha256_file(path) != digest:
            changed.append(name)

    added = []
    lean_dir = os.path.join(root, "lean")
    for dirpath, dirnames, filenames in os.walk(lean_dir):
        if os.path.relpath(dirpath, lean_dir) == ".":
            dirnames[:] = [d for d in dirnames if d != ".lake"]
        for fn in filenames:
            rel = os.path.relpath(os.path.join(dirpath, fn), root).replace(os.sep, "/")
            if rel not in expected:
                added.append(rel)

    print(f"archive files: {len(expected)}  changed: {len(changed)}  "
          f"missing: {len(missing)}  added: {len(added)}")
    for label, items in (("CHANGED", changed), ("MISSING", missing), ("ADDED", added)):
        for item in items[:50]:
            print(f"  {label}: {item}")
    sys.exit(1 if (changed or missing or added) else 0)


if __name__ == "__main__":
    main()

"""Manage explicitly registered Linux build scratch and verified, size-limited copies."""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import re
import signal
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

MIB = 1024 ** 2
GUARD = Path(__file__).with_name("build-storage-guard.sh")
MAGIC = "y700-build-scratch-v1"
JOB = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,47}")
OBJECT = re.compile(r"[0-9a-f]{64}\.zst")


def require(condition, message):
    if not condition:
        raise ValueError(message)


@contextlib.contextmanager
def lockdir(path, busy="store"):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError(f"{busy} busy") from None
        yield fd
    finally:
        os.close(fd)


def save(path, record):
    with tempfile.NamedTemporaryFile(dir=path.parent, mode="w", delete=False) as file:
        json.dump(record, file)
        file.write("\n")
        file.flush()
        os.fsync(file.fileno())
    os.replace(file.name, path)
    syncdir(path.parent)


def syncdir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def read(path):
    require(path.is_file() and not path.is_symlink(), "missing managed record")
    return json.loads(path.read_text())


def private(path):
    st = path.lstat()
    require(stat.S_ISDIR(st.st_mode) and st.st_uid == os.geteuid() and
            stat.S_IMODE(st.st_mode) == 0o700, "expected private owned Linux directory")


def objects(store):
    files = list((store / "objects").iterdir())
    for item in files:
        require(OBJECT.fullmatch(item.name) and stat.S_ISREG(item.lstat().st_mode),
                "unexpected archive entry; retained for inspection")
    return files


def unpack_hash(path, anonymous=False):
    command = ["zstd", "-q", "-d", "-c"]
    if not anonymous:
        command += ["--", path]
    with subprocess.Popen(command, stdin=path if anonymous else subprocess.DEVNULL,
                          stdout=subprocess.PIPE) as proc:
        digest = hashlib.file_digest(proc.stdout, "sha256").hexdigest()
        require(proc.wait() == 0, "archive could not be decoded")
    return digest


def job_paths(store, name):
    require(JOB.fullmatch(name), "invalid job identifier")
    return store / "jobs" / name


def regular(work, relative):
    rel = Path(relative)
    require(not rel.is_absolute() and ".." not in rel.parts and rel.parts,
            "expected relative scratch filename")
    path = work / rel
    require(path.resolve(strict=True) == path and stat.S_ISREG(path.lstat().st_mode),
            "only a regular file inside this job can be selected")
    target = hashlib.sha256(os.fsencode(str(rel))).hexdigest()
    return path, work.parent / "records" / target


def fingerprint(st):
    return (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns)


@contextlib.contextmanager
def controlled_file(path, exclusive=False):
    flags = os.O_RDWR if exclusive else os.O_RDONLY
    fd = os.open(path, flags | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "r+b" if exclusive else "rb") as file:
        if exclusive:
            # A write lease rejects open/mapped/loop-backed files, including readers
            # outside our PID namespace. A competing open requests a lease break.
            fcntl.fcntl(fd, fcntl.F_SETLEASE, fcntl.F_WRLCK)
        before = fingerprint(os.fstat(fd))
        require(before == fingerprint(path.lstat()), "scratch file changed")
        yield file, before


def check_mounts(work):
    # Same-device bind mounts do not reliably appear in os.path.ismount().
    for line in Path("/proc/self/mountinfo").read_bytes().splitlines():
        raw = line.split(b" ")[4]
        value = re.sub(rb"\\([0-7]{3})", lambda m: bytes([int(m[1], 8)]), raw)
        path = Path(os.fsdecode(value))
        require(path not in (work.parent.parent, work.parent, work) and work not in path.parents,
                "mounted scratch retained")


def archive(store, job, rel, policy):
    work = job / "work"
    path, record = regular(work, rel)
    check_mounts(work)
    with controlled_file(path) as (file, before):
        digest = hashlib.file_digest(file, "sha256").hexdigest()
        target = store / "objects" / (digest + ".zst")
        current = objects(store)
        if target not in current:
            remaining = policy["total"] - sum(item.stat().st_size for item in current)
            cap = min(policy["single"], remaining)
            require(len(current) < policy["count"] and cap > 0, "archive quota reached")
            budget = min(cap, before[2] + before[2] // 128 + MIB)
            with lockdir("/var/tmp", "image build"):
                subprocess.run(["bash", GUARD, "archive", store, "check", str((budget + MIB - 1) // MIB)], check=True)
                file.seek(0)
                # Anonymous staging is released by the kernel even if the worker dies.
                tmpfd = os.open(target.parent, os.O_TMPFILE | os.O_RDWR, 0o600)
                with os.fdopen(tmpfd, "w+b") as tmp:
                    with subprocess.Popen(["zstd", "-q", "-T1", "-3", "-c"], stdin=file,
                                          stdout=subprocess.PIPE) as proc:
                        try:
                            while chunk := proc.stdout.read(MIB):
                                require(tmp.tell() + len(chunk) <= cap, "compressed archive exceeds quota")
                                tmp.write(chunk)
                            require(proc.wait() == 0, "compression failed")
                        finally:
                            if proc.poll() is None:
                                proc.kill()
                    tmp.flush()
                    os.fsync(tmp.fileno())
                    tmp.seek(0)
                    require(unpack_hash(tmp, anonymous=True) == digest, "compressed copy differed")
                    srcfd = os.open("/proc/self/fd", os.O_RDONLY | os.O_DIRECTORY)
                    try:
                        os.link(str(tmpfd), target, src_dir_fd=srcfd, follow_symlinks=True)
                    finally:
                        os.close(srcfd)
                    syncdir(target.parent)
        else:
            require(unpack_hash(target) == digest, "existing archive differs")
        require(fingerprint(path.lstat()) == before, "input changed during archive; kept source")
        st = path.lstat()
        save(record, {"raw": digest, "size": before[2], "mode": stat.S_IMODE(st.st_mode),
                      "uid": st.st_uid, "gid": st.st_gid, "mtime_ns": st.st_mtime_ns})
        print(f"archived raw_sha256={digest} archive_bytes={target.stat().st_size}")


def prune(store, job, relative):
    work = job / "work"
    path, record = regular(work, relative)
    saved = read(record)
    digest = saved["raw"]
    require(re.fullmatch(r"[a-f0-9]{64}", digest), "invalid archive reference")
    check_mounts(work)
    target = store / "objects" / (digest + ".zst")
    require(target in objects(store) and unpack_hash(target) == digest, "verified archive required")
    with controlled_file(path, exclusive=True) as (file, before):
        st = os.fstat(file.fileno())
        require(not os.listxattr(file.fileno()) and st.st_nlink == 1 and
                (stat.S_IMODE(st.st_mode), st.st_uid, st.st_gid, st.st_mtime_ns) ==
                (saved["mode"], saved["uid"], saved["gid"], saved["mtime_ns"]),
                "file with links, attributes or changed metadata retained")
        require(before[2] == saved["size"] and hashlib.file_digest(file, "sha256").hexdigest() == digest,
                "changed scratch retained")
        require(fingerprint(path.lstat()) == before and
                fcntl.fcntl(file.fileno(), fcntl.F_GETLEASE) == fcntl.F_WRLCK, "busy scratch retained")
        path.unlink()
        syncdir(path.parent)
    print(f"pruned verified_duplicate_bytes={before[2]}")


def main(args):
    raw = args.store.absolute()
    require(raw.resolve() == raw and raw != Path("/"), "store must have a direct, non-symlink path")
    if args.cmd == "init":
        require(0 < args.single <= args.total and args.count > 0, "invalid archive limits")
        raw.mkdir(mode=0o700)
        for name in ("jobs", "objects"):
            (raw / name).mkdir(mode=0o700)
        save(raw / "policy", dict(format=MAGIC, count=args.count, single=args.single, total=args.total))
        return
    for directory in (raw, raw / "jobs", raw / "objects"):
        private(directory)
    policy = read(raw / "policy")
    require(policy.get("format") == MAGIC, "unrecognized store")
    if args.cmd == "status":
        files = objects(raw)
        print(f"archives={len(files)}/{policy['count']} bytes={sum(f.stat().st_size for f in files)}/{policy['total']} single_limit={policy['single']}")
        for job in sorted((raw / "jobs").iterdir()):
            private(job)
            state = read(job / "state")
            try:
                with lockdir(job):
                    if state == "running":
                        state = "interrupted"
            except ValueError:
                state += " (busy)"
            print(f"job={job.name} state={state}")
        return subprocess.run(["bash", GUARD, "status", raw, "check"]).returncode
    if args.cmd == "retire":
        digest = args.raw_sha256
        require(re.fullmatch(r"[0-9a-f]{64}", digest), "invalid raw SHA-256")
        with lockdir(raw):
            target = raw / "objects" / (digest + ".zst")
            copy = args.copy.resolve(strict=True)
            require(raw not in copy.parents and target in objects(raw) and not copy.samefile(target)
                    and stat.S_ISREG(copy.stat().st_mode), "independent external regular copy required")
            with controlled_file(copy) as (file, before):
                require(unpack_hash(file, anonymous=True) == digest and fingerprint(copy.stat()) == before,
                        "external copy differs")
            target.unlink()
            syncdir(target.parent)
        return
    job = job_paths(raw, args.job)
    if args.cmd == "run":
        require(bool(args.command), "missing build command")
        with lockdir(raw):
            job.mkdir(mode=0o700)
            for name in ("work", "records"):
                (job / name).mkdir(mode=0o700)
            save(job / "state", "running")
            lease = os.open(job, os.O_RDONLY | os.O_DIRECTORY)
            fcntl.flock(lease, fcntl.LOCK_EX)
        try:
            try:
                result = subprocess.run(args.command, cwd=job / "work", pass_fds=(lease,),
                                        env=dict(os.environ, Y700_BUILD_SCRATCH=str(job / "work")))
            except OSError:
                save(job / "state", "failed")
                raise
            save(job / "state", "succeeded" if result.returncode == 0 else "failed")
            return result.returncode if result.returncode >= 0 else 128 - result.returncode
        finally:
            os.close(lease)
    for directory in (job, job / "work", job / "records"):
        private(directory)
    with lockdir(raw), lockdir(job, "job"):
        require(read(job / "state") in ("running", "succeeded", "failed"), "unrecognized job state")
        if args.cmd == "archive":
            archive(raw, job, args.file, policy)
        else:
            prune(raw, job, args.file)


def interrupted(signum, frame):
    raise ValueError("competing file open; original retained")


if __name__ == "__main__":
    os.umask(0o077)
    signal.signal(signal.SIGIO, interrupted)
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="cmd", required=True)
    for action in ("init", "status", "run", "archive", "prune", "retire"):
        cli = actions.add_parser(action)
        cli.add_argument("store", type=Path)
        if action == "init":
            cli.add_argument("--count", type=int, default=4)
            cli.add_argument("--single", type=int, default=4 * 1024 ** 3)
            cli.add_argument("--total", type=int, default=8 * 1024 ** 3)
        if action in ("run", "archive", "prune"):
            cli.add_argument("job")
        if action == "run":
            cli.add_argument("command", nargs=argparse.REMAINDER)
        if action in ("archive", "prune"):
            cli.add_argument("file")
        if action == "retire":
            cli.add_argument("raw_sha256")
            cli.add_argument("copy", type=Path)
    try:
        sys.exit(main(parser.parse_args()))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))

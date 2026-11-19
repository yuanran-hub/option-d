"""Install both relocatable Mac interpreters, their notices, and universal wheels."""
import hashlib
import shutil
import subprocess
import sys
import tarfile
import zipfile
from pathlib import Path

CACHE = Path(__file__).resolve().parents[1] / ".build/portable"
TAG = "20261110"
PYTHON_VERSION = "3.12.16"
UPSTREAM = "https://github.com/astral-sh/python-build-standalone"
INTERPRETERS = {
    "aarch64": "2f11b8aa3726bdbd87dd9eb76568412faddf4f47e26913fa45d6a2e424972acd",
    "x86_64": "b78a4c479f1964ec484880bee567568266f68da102269fb93a05fe8716b45f91",
}
WHEELS = {
    "d0/00/1e03a4989fa5795da308cd774f05b704ace555a70f9bf9d3be057b680bcf/python_docx-1.2.0-py3-none-any.whl":
        "3fd478f3250fbbbfd3b94fe1e985955737c145627498896a8a6bf81f4baf66c7",
    "dd/1f/a180b57d9eeabaab77f9d5aa30356898ea749c4795596a8f66d1eb6bef2e/lxml-6.1.3-cp312-cp312-macosx_10_13_universal2.whl":
        "0c0710ac085a157b593c38fbcacd950f15c4afa8e2057527185875ab302752bc",
    "49/d3/b8441a820a491ddfc024b0b0cf0393375b75ea13866d9c66727e54c2fc80/typing_extensions-4.16.0-py3-none-any.whl":
        "481caa481374e813c1b176ada14e97f1f67a4539ce9cfeb3f350d78d6370c2e8",
}


def cached(name, url, digest):
    path = CACHE / name
    if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == digest:
        return path
    temp = path.with_suffix(".download")
    subprocess.run(["curl", "-fL", "--retry", "3", "--output", str(temp), url], check=True)
    if hashlib.sha256(temp.read_bytes()).hexdigest() != digest:
        raise ValueError("Checksum mismatch for " + name)
    temp.replace(path)
    return path


def install(resources):
    CACHE.mkdir(parents=True, exist_ok=True)
    runtime = resources / "runtime"
    for cpu, digest in INTERPRETERS.items():
        name = f"cpython-{PYTHON_VERSION}%2B{TAG}-{cpu}-apple-darwin-install_only_stripped.tar.gz"
        archive = cached(cpu + ".tar.gz", f"{UPSTREAM}/releases/download/{TAG}/{name}", digest)
        target = runtime / cpu
        target.mkdir()
        subprocess.run(["tar", "-xzf", str(archive), "-C", str(target), "--strip-components", "1",
                        "--exclude", "*/site-packages/*", "--exclude", "*/__pycache__/*",
                        "python/bin/python3.12", "python/lib"], check=True)

    notices = resources / "licenses/python-build-standalone"
    notices.mkdir()
    archive = cached(f"python-build-standalone-{TAG}.tar.gz",
                     f"https://codeload.github.com/astral-sh/python-build-standalone/tar.gz/refs/tags/{TAG}",
                     "63b8166347616283ee6d3ed449e957bc71b65368bc60945d21ab957e6fcaee49")
    with tarfile.open(archive) as source:
        for member in source:
            path = Path(member.name)
            if len(path.parts) == 2 and path.name.startswith("LICENSE") and member.isfile():
                with (notices / path.name).open("wb") as output:
                    shutil.copyfileobj(source.extractfile(member), output)

    for location, digest in WHEELS.items():
        wheel = cached(Path(location).name, "https://files.pythonhosted.org/packages/" + location, digest)
        with zipfile.ZipFile(wheel) as package:
            package.extractall(runtime / "vendor")


if __name__ == "__main__":
    install(Path(sys.argv[1]))

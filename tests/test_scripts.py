"""Скрипты образа: синтаксис, обязательные COPY в Dockerfile, populate-volume.sh.

Проверки не требуют Docker/GPU/сети: ``bash -n`` для синтаксиса и прогоны
populate-volume.sh на временном «томе» с локальным манифестом.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which("bash")

pytestmark = pytest.mark.skipif(BASH is None, reason="нужен bash для проверки shell-скриптов")


def _run(args: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(args, capture_output=True, text=True, cwd=ROOT, **kwargs)


@pytest.mark.parametrize("script", [
    "populate-volume.sh",
    "docker/entrypoint.sh",
    "docker/install-comfy-packages.sh",
    "scripts/wait-comfy.sh",
])
def test_shell_syntax(script: str) -> None:
    result = _run([BASH, "-n", script])
    assert result.returncode == 0, result.stderr


def _manifest(tmp_path: Path, rows: list[str]) -> Path:
    path = tmp_path / "models-manifest.txt"
    path.write_text("\n".join(rows) + "\n", encoding="utf-8")
    return path


def _populate(tmp_path: Path, manifest: Path, extra_env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
    (tmp_path / "volume").mkdir(exist_ok=True)
    env = {
        **os.environ,
        "VOL_ROOT": str(tmp_path / "volume"),
        "MANIFEST": str(manifest),
    }
    env.pop("HF_TOKEN", None)
    if extra_env:
        env.update(extra_env)
    return _run([BASH, "populate-volume.sh"], env=env)


def _pinned_url(name: str, commit: str = "a" * 40) -> str:
    return f"https://huggingface.co/org/repo/resolve/{commit}/split_files/diffusion_models/{name}"


def test_populate_rejects_main(tmp_path: Path) -> None:
    manifest = _manifest(tmp_path, [
        f"diffusion_models\tx.safetensors\thttps://huggingface.co/org/repo/resolve/main/x.safetensors\t{'b' * 64}",
    ])
    result = _populate(tmp_path, manifest)
    assert result.returncode != 0
    assert "main" in result.stderr.lower()


def test_populate_rejects_unresolved_placeholder(tmp_path: Path) -> None:
    manifest = _manifest(tmp_path, [
        "diffusion_models\tx.safetensors\t"
        "https://huggingface.co/org/repo/resolve/${MODEL_REV}/x.safetensors\t" + "b" * 64,
    ])
    result = _populate(tmp_path, manifest)
    assert result.returncode != 0
    assert "MODEL_REV" in result.stderr
    assert "не заданы переменные" in result.stderr


def test_populate_skips_existing_verified_file(tmp_path: Path) -> None:
    content = b"already-downloaded-model"
    sha = hashlib.sha256(content).hexdigest()
    manifest = _manifest(tmp_path, [
        f"diffusion_models\tx.safetensors\t{_pinned_url('x.safetensors')}\t{sha}",
    ])
    target = tmp_path / "volume" / "models" / "diffusion_models" / "x.safetensors"
    target.parent.mkdir(parents=True)
    target.write_bytes(content)

    result = _populate(tmp_path, manifest)
    assert result.returncode == 0, result.stderr
    assert "[populate]" in result.stdout
    assert "есть diffusion_models/x.safetensors (sha256 ok)" in result.stdout
    assert target.read_bytes() == content
    # Layout тома создаётся заранее.
    assert (tmp_path / "volume" / "custom_nodes").is_dir()
    assert (tmp_path / "volume" / "encoder-cache").is_dir()
    assert (tmp_path / "volume" / "models" / ".populate-state.tsv").is_file()


def test_populate_reports_manifest_format_error(tmp_path: Path) -> None:
    manifest = _manifest(tmp_path, [
        f"diffusion_models\tx.safetensors\t{_pinned_url('x.safetensors')}\t{'b' * 64}\tEXTRA",
    ])
    result = _populate(tmp_path, manifest)
    assert result.returncode != 0
    assert "лишняя колонка" in result.stderr


def test_populate_downloads_verifies_and_renames_atomically(tmp_path: Path) -> None:
    # Локальный file:// источник с commit-пином в пути: проверяем полный путь
    # скачивания (curl), sha256, атомарный mv и запись состояния тома.
    source_dir = tmp_path / "source" / "resolve" / ("c" * 40)
    source_dir.mkdir(parents=True)
    content = b"fresh-model-bytes"
    (source_dir / "x.safetensors").write_bytes(content)
    sha = hashlib.sha256(content).hexdigest()
    url = f"file://{(source_dir / 'x.safetensors').as_posix()}"
    manifest = _manifest(tmp_path, [f"diffusion_models\tx.safetensors\t{url}\t{sha}"])

    result = _populate(tmp_path, manifest)
    assert result.returncode == 0, result.stderr
    target = tmp_path / "volume" / "models" / "diffusion_models" / "x.safetensors"
    assert target.read_bytes() == content
    assert not (target.parent / "x.safetensors.tmp").exists()
    state = (tmp_path / "volume" / "models" / ".populate-state.tsv").read_text(encoding="utf-8")
    assert f"diffusion_models/x.safetensors\t{sha}" in state


def test_populate_expands_pinned_revision_placeholder(tmp_path: Path) -> None:
    content = b"model-bytes"
    sha = hashlib.sha256(content).hexdigest()
    manifest = _manifest(tmp_path, [
        "diffusion_models\tx.safetensors\t"
        "https://huggingface.co/org/repo/resolve/${MODEL_REV}/x.safetensors\t" + sha,
    ])
    target = tmp_path / "volume" / "models" / "diffusion_models" / "x.safetensors"
    target.parent.mkdir(parents=True)
    target.write_bytes(content)

    result = _populate(tmp_path, manifest, {"MODEL_REV": "d" * 40})
    assert result.returncode == 0, result.stderr
    assert "есть diffusion_models/x.safetensors (sha256 ok)" in result.stdout


def test_dockerfile_copy_sources_exist() -> None:
    text = (ROOT / "Dockerfile").read_text(encoding="utf-8")
    copies = re.findall(r"^COPY\s+(\S+)\s+\S+", text, flags=re.MULTILINE)
    assert copies, "в Dockerfile нет COPY"
    for source in copies:
        assert (ROOT / source).exists(), f"COPY {source}: источника нет в репозитории"


def test_runpod_metadata_is_valid_json() -> None:
    hub = json.loads((ROOT / ".runpod" / "hub.json").read_text(encoding="utf-8"))
    tests = json.loads((ROOT / ".runpod" / "tests.json").read_text(encoding="utf-8"))
    assert hub["type"] == "serverless"
    assert hub["config"]["gpuIds"]
    assert hub["config"]["env"]
    assert tests["tests"][0]["input"] == {"action": "health"}
    assert "VOLUME_AUTOPOPULATE" in {item["key"] for item in tests["config"]["env"]}

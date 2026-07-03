from pathlib import Path


def test_deleted_legacy_modules_absent():
    root = Path(__file__).resolve().parents[1]
    assert not (root / "src/local_llm/eval_capture/writer.py").exists()
    assert not (root / "src/local_llm/store/sqlite_store.py").exists()
    assert not (root / "src/local_llm/store/migrations.py").exists()
    assert not (root / "src/local_llm/runs/runner.py").exists()
    assert not (root / "src/local_llm/runs/inspector.py").exists()
    assert not (root / "src/local_llm/runs/__init__.py").exists()
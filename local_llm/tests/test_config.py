from pathlib import Path

import yaml

from local_llm.config import AppConfig


def test_example_config_parses():
    data = yaml.safe_load(Path("config.example.yaml").read_text())
    cfg = AppConfig.model_validate(data)
    assert "local_basic" in cfg.model_profiles
    assert "primary_local_corpus" in cfg.corpora

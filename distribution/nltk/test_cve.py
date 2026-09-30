from __future__ import annotations

import json
import pickle
import tempfile
from pathlib import Path

import nltk
import numpy as np
import pytest
from nltk import pathsec
from nltk.classify.maxent import load_maxent_params, save_maxent_params
from nltk.data import FileSystemPathPointer
from nltk.parse import transitionparser
from nltk.parse.transitionparser import TransitionParser
from nltk.tag.perceptron import AveragedPerceptron, PerceptronTagger

ENDPOINTS = (
    "perceptron_save",
    "perceptron_load",
    "tagger_save",
    "maxent_save",
    "parser_train",
    "parser_parse",
)
WEIGHTS = {"bias": {"NN": 1.0}}


class _FakeArray:
    def __init__(self) -> None:
        self.indices = self
        self.indptr = self

    def astype(self, *args: object, **kwargs: object) -> _FakeArray:
        return self


class _FakeModel:
    def fit(self, *args: object) -> _FakeModel:
        return self


class _FakeSVM:
    @staticmethod
    def SVC(**kwargs: object) -> _FakeModel:
        return _FakeModel()


@pytest.fixture
def sandbox(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> tuple[Path, Path]:
    root, outside, staging = (
        tmp_path / name for name in ("allowed", "outside", "staging")
    )
    for directory in (root, outside, staging):
        directory.mkdir(mode=0o700)
    monkeypatch.setenv("NLTK_DATA", str(root))
    monkeypatch.setenv("TMPDIR", str(staging))
    monkeypatch.setattr(tempfile, "tempdir", str(staging))
    monkeypatch.setattr(nltk.data, "path", [str(root)])
    monkeypatch.setattr(pathsec, "ENFORCE", True)
    monkeypatch.setattr(pathsec, "_ALLOWED_ROOTS_CACHE", None)
    monkeypatch.setattr(pathsec, "_LAST_DATA_PATHS", None)
    monkeypatch.setattr(
        transitionparser,
        "load_svmlight_file",
        lambda _: (_FakeArray(), None),
        raising=False,
    )
    monkeypatch.setattr(transitionparser, "svm", _FakeSVM, raising=False)
    monkeypatch.setattr(
        TransitionParser,
        "_create_training_examples_arc_std",
        lambda *args: [],
        raising=False,
    )
    return root, outside


def plant_inert_inputs(directory: Path) -> None:
    (directory / "source.json").write_text(json.dumps(WEIGHTS), encoding="utf-8")
    (directory / "source.model").write_bytes(pickle.dumps(None))


def call_endpoint(endpoint: str, directory: Path) -> object:
    if endpoint == "perceptron_save":
        return AveragedPerceptron(WEIGHTS).save(directory / "written.json")
    if endpoint == "perceptron_load":
        return AveragedPerceptron().load(directory / "source.json")
    if endpoint == "tagger_save":
        tagger = PerceptronTagger(load=False)
        tagger.model.weights = WEIGHTS
        tagger.classes = {"NN"}
        return tagger.save_to_json("eng", str(directory / "tagger"))
    if endpoint == "maxent_save":
        return save_maxent_params(
            np.array([1.0]),
            {("word", "dog", "NN"): 0},
            ["NN"],
            {"NN": 0},
            str(directory / "maxent"),
        )
    if endpoint == "parser_train":
        return TransitionParser("arc-standard").train(
            [], str(directory / "trained.model"), False
        )
    return TransitionParser("arc-standard").parse([], str(directory / "source.model"))


@pytest.mark.parametrize("endpoint", ENDPOINTS)
def test_advisory_api_denies_same_path_as_central_guard(
    endpoint: str, sandbox: tuple[Path, Path]
) -> None:
    _, outside = sandbox
    plant_inert_inputs(outside)
    before = {item.name: item.read_bytes() for item in outside.iterdir()}
    with pytest.raises(PermissionError):
        call_endpoint(endpoint, outside)
    assert {item.name: item.read_bytes() for item in outside.iterdir()} == before


@pytest.mark.parametrize("endpoint", ENDPOINTS)
def test_central_guard_negative_control(
    endpoint: str, sandbox: tuple[Path, Path]
) -> None:
    _, outside = sandbox
    target = outside / (
        "source.json" if endpoint.endswith(("load", "parse")) else "written.json"
    )
    target.write_text("unchanged", encoding="utf-8")
    with pytest.raises(PermissionError):
        pathsec.open(target, "r" if endpoint.endswith(("load", "parse")) else "w")
    assert target.read_text(encoding="utf-8") == "unchanged"


@pytest.mark.parametrize("endpoint", ENDPOINTS)
def test_advisory_api_accepts_allowed_path(
    endpoint: str, sandbox: tuple[Path, Path]
) -> None:
    root, _ = sandbox
    plant_inert_inputs(root)
    call_endpoint(endpoint, root)


@pytest.mark.parametrize("endpoint", ENDPOINTS)
def test_existing_enforcement_disabled_behavior(
    endpoint: str, sandbox: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    _, outside = sandbox
    plant_inert_inputs(outside)
    monkeypatch.setattr(pathsec, "ENFORCE", False)
    call_endpoint(endpoint, outside)


@pytest.mark.parametrize("endpoint", ["tagger_save", "maxent_save"])
def test_rejected_directory_does_not_expand_trusted_roots(
    endpoint: str, sandbox: tuple[Path, Path]
) -> None:
    _, outside = sandbox
    roots = set(pathsec._get_allowed_roots())
    with pytest.raises(PermissionError):
        call_endpoint(endpoint, outside)
    assert set(pathsec._get_allowed_roots()) == roots
    assert list(outside.iterdir()) == []


def test_allowed_perceptron_round_trip(sandbox: tuple[Path, Path]) -> None:
    root, _ = sandbox
    filename = root / "weights.json"
    AveragedPerceptron(WEIGHTS).save(filename)
    restored = AveragedPerceptron()
    restored.load(filename)
    assert restored.weights == WEIGHTS


def test_allowed_tagger_round_trip(sandbox: tuple[Path, Path]) -> None:
    root, _ = sandbox
    directory = root / "tagger"
    tagger = PerceptronTagger(load=False)
    tagger.model.weights = WEIGHTS
    tagger.classes = {"NN"}
    tagger.save_to_json("eng", str(directory))
    restored = PerceptronTagger(load=False)
    restored.load_from_json("eng", str(directory))
    assert restored.model.weights == WEIGHTS
    assert restored.classes == {"NN"}


def test_allowed_maxent_round_trip(sandbox: tuple[Path, Path]) -> None:
    root, _ = sandbox
    directory = root / "maxent"
    mapping = {("word", "dog", "NN"): 0}
    save_maxent_params(np.array([1.0]), mapping, ["NN"], {"NN": 0}, str(directory))
    weights, restored_mapping, labels, always_on = load_maxent_params(
        FileSystemPathPointer(str(directory))
    )
    assert weights.tolist() == [1.0]
    assert restored_mapping == mapping
    assert labels == ["NN"]
    assert always_on == {"NN": 0}

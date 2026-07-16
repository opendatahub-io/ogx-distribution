# Copyright (c) Red Hat
# All rights reserved.
#
# This source code is licensed under the terms described in the LICENSE file in
# the root directory of this source tree.

import re
from pathlib import Path

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

_VERSION_PATTERN = re.compile(r"^[0-9a-zA-Z._+\-/]+$")


class BuildConfig(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=Path(__file__).parent / "build.env",
    )

    ogx_version: str
    ogx_install_from_source: bool = False
    rhai_index_url: str | None = None

    @field_validator("ogx_version")
    @classmethod
    def check_version(cls, v: str) -> str:
        if not v or not _VERSION_PATTERN.match(v):
            raise ValueError(
                f"Invalid version format: {v!r}. "
                "Only alphanumeric characters, dots, hyphens, plus signs, "
                "underscores, and slashes are allowed."
            )
        return v

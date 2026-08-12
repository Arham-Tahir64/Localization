from __future__ import annotations

from typing import Any


class HouseMapperServerError(Exception):
    """Base class for expected, user-facing server failures."""


class ContractError(HouseMapperServerError):
    """An input violates a versioned HouseMapper contract."""


class PackageError(HouseMapperServerError):
    """A saved HouseMapper package is incomplete or inconsistent."""


class MapBuildError(HouseMapperServerError):
    """A calibrated feature map could not be constructed safely."""


class LocalizationError(HouseMapperServerError):
    """The query did not produce a sufficiently verified 6DoF pose."""

    def __init__(
        self,
        message: str,
        *,
        stage: str = "unknown",
        diagnostics: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(message)
        self.stage = stage
        self.diagnostics = diagnostics or {}

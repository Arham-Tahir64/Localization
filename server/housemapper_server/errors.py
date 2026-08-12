from __future__ import annotations


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

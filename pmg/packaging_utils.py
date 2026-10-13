"""Requirement and version parsing using `packaging`.

Does not import any transient dependencies on import, can be imported globally.
"""

from __future__ import annotations

import re
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from packaging.requirements import Requirement
    from packaging.version import Version


OWN_MARK = re.compile(r"^(\s*[A-Za-z0-9][A-Za-z0-9._-]*)!(?!=)")
"""The `!` after the name of a dependency that must be a version installed by pmg."""


def strip_own(dep: str) -> str:
    """Returns the dependency without the mark `!` that asks for a version installed by pmg."""
    return OWN_MARK.sub(r"\1", dep)


def own_names(deps: list[str]) -> set[str]:
    """Returns the names of the dependencies for the host that carry the mark `!`."""
    return {
        requirement.name
        for dep, requirement in zip(deps, requirements(deps, keep_all=True), strict=True)
        if OWN_MARK.match(dep) and (not requirement.marker or requirement.marker.evaluate())
    }


def requirements(deps: list[str], keep_all: bool = False) -> list[Requirement]:
    """Parses dependencies like "lib>=1.2,<2" or "lib; sys_platform == 'linux'" for the host.

    Dependencies whose environment marker does not match the host are left out, unless `keep_all`
    is set. A `!` after the name, as in "lib!", only matters for the installation, see `own_names`.

    Raises:
        ValueError: If a dependency is invalid or has extras or a URL.
    """
    from packaging.requirements import Requirement

    parsed = [Requirement(strip_own(dep)) for dep in deps]
    for requirement in parsed:
        if requirement.extras or requirement.url:  # pragma: no cover
            raise ValueError(
                f"only a name, a version specifier, and a marker are allowed: {requirement}"
            )
    if keep_all:
        return parsed
    return [
        requirement
        for requirement in parsed
        if not requirement.marker or requirement.marker.evaluate()
    ]


def tag_version(tag: str) -> Version | None:
    """Returns the first version in a release tag, e.g. 1.27.1 in go1.27.1."""
    from packaging.version import InvalidVersion, Version

    match = re.search(r"\d+(?:\.\d+)*", tag)
    if match is None:  # pragma: no cover
        return None
    try:
        return Version(match.group())
    except InvalidVersion:  # pragma: no cover
        return None

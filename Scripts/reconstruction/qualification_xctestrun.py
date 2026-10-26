"""Resolve one exact Xcode 27 SDK product without changing deployment policy."""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import stat


SCHEMES = ("MacScopeApp", "MacScopeInstalledAppUITests")


def resolve_xctestrun(
    products_root: Path, scheme: str, sdk_version: str, *, allow_missing: bool = False
) -> Path:
    """Bind the filename to SDK identity and reject ambiguous or indirect products.

    Missing is permitted only for the pre-build product-inventory check. Receipt
    producers/consumers must use the default, which requires the physical file.
    Plist semantics and hashes remain the preparation receipt owner's checks.
    """
    if scheme not in SCHEMES or not re.fullmatch(r"27\.\d+(?:\.\d+)?", sdk_version):
        raise ValueError("qualification xctestrun requires a governed scheme and Xcode 27 SDK")
    if not products_root.is_absolute() or products_root.resolve() != products_root:
        raise ValueError("qualification products root must be canonical and symlink-free")
    expected = products_root / f"{scheme}_macosx{sdk_version}-arm64.xctestrun"
    if not products_root.exists():
        if allow_missing:
            return expected
        raise ValueError("qualification products root is absent")
    if not products_root.is_dir():
        raise ValueError("qualification products root is not a directory")
    products = sorted(products_root.glob(f"{scheme}_*.xctestrun"))
    # UI runners retain separately validated execution overlays beside the
    # prepared plan. Admit only the documented producer suffixes at this exact
    # SDK/architecture; overlays can never replace the prepared base plan.
    overlay_pattern = re.compile(re.escape(expected.stem) +
                                 r"-(?:Task10OptIn-[0-9a-f]{64}|AdaptivePaneOptIn(?:-Retry[1-9][0-9]*)?)\.xctestrun")
    overlays = [path for path in products
                if scheme == "MacScopeInstalledAppUITests" and overlay_pattern.fullmatch(path.name)]
    matches = [path for path in products if path not in overlays]
    if not matches and not overlays and allow_missing:
        return expected
    if matches != [expected]:
        raise ValueError("qualification xctestrun is absent, ambiguous, or differs from the exact SDK")
    for path in [expected, *overlays]:
        metadata = path.lstat()
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_nlink != 1
            or path.resolve(strict=True) != path
            or not 0 < metadata.st_size <= 16 * 1024 * 1024
        ):
            raise ValueError("qualification xctestrun must be one bounded physical ordinary file")
    return expected


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--products-root", required=True, type=Path)
    parser.add_argument("--scheme", required=True, choices=SCHEMES)
    parser.add_argument("--sdk-version", required=True)
    parser.add_argument("--allow-missing", action="store_true")
    arguments = parser.parse_args()
    try:
        print(resolve_xctestrun(arguments.products_root, arguments.scheme,
                               arguments.sdk_version, allow_missing=arguments.allow_missing))
    except (OSError, ValueError) as error:
        parser.exit(1, f"qualification xctestrun refused: {error}\n")


if __name__ == "__main__":
    main()

"""Contract tests for the CA-download Homarr tile.

The tile is consumed by homarr-container-adapter's registry loader; a malformed
file or a drift between icon_url and the install path would silently drop the
tile or its icon at runtime. These checks are Docker-free and run in CI via the
pytest step.
"""

import tomllib
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TILE = REPO / "assets" / "ca-download-tile.toml"
RULES = REPO / "debian" / "rules"
ICON = REPO / "assets" / "halos-ca-download.svg"


def _load():
    with TILE.open("rb") as f:
        return tomllib.load(f)


def test_parses():
    _load()


def test_required_fields_present_and_typed():
    d = _load()
    assert d["name"]
    assert d["description"]
    assert d["url"] == "/ca/"
    assert d["icon_url"] == "/usr/share/pixmaps/halos-ca-download.svg"
    assert d["visible"] is True
    assert d["type"]["external"] is True
    assert isinstance(d["layout"]["priority"], int)


def test_url_is_path_only():
    # Mirrors homarr-container-adapter is_path_only: leading '/', second char not '/'.
    url = _load()["url"]
    assert url.startswith("/") and len(url) > 1 and url[1] != "/"


def test_icon_source_exists_and_install_path_matches():
    icon_url = _load()["icon_url"]
    assert ICON.exists(), "icon_url has no source SVG at assets/halos-ca-download.svg"
    rules = RULES.read_text()
    # debian/rules must install the SVG to exactly the path icon_url points at,
    # and install the tile into the directory the adapter reads.
    assert icon_url.lstrip("/") in rules
    assert "etc/halos/webapps.d/ca-download.toml" in rules
    assert "assets/halos-ca-download.svg" in rules

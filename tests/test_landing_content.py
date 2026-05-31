"""Content guard for the CA-trust landing page.

Asserts the per-OS walkthrough is structurally present and each platform's
trust step survives. Reads the HTML directly, so unlike the Docker-gated
endpoint test this runs in CI and catches a regression to the Unit 1
placeholder. Markers are section-unique to avoid passing on incidental matches
(e.g. "CA certificate" also appears in the download button).
"""

from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
HTML = (REPO / "assets" / "ca-download" / "landing" / "index.html").read_text()


@pytest.mark.parametrize("os_id", ["macos", "ios", "android", "linux", "windows"])
def test_platform_section_present(os_id):
    # The id is load-bearing: the UA-detection script opens sections by id.
    assert f'id="{os_id}"' in HTML


def test_trust_vs_install_caveat_present():
    assert "Installing the certificate is not enough" in HTML


@pytest.mark.parametrize(
    "marker",
    [
        "Always Trust",  # macOS Keychain trust step
        "Certificate Trust Settings",  # iOS trust toggle
        "Android trusts user-installed CAs in browsers only",  # Android-unique
        "update-ca-certificates",  # Linux system store
        "Trusted Root Certification Authorities",  # Windows store
    ],
)
def test_platform_trust_marker_present(marker):
    assert marker in HTML

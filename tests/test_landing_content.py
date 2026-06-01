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
HTML = (REPO / "assets" / "ca-download" / "www" / "ca" / "index.html").read_text()


@pytest.mark.parametrize("os_id", ["macos", "ios", "android", "linux", "windows"])
def test_platform_section_present(os_id):
    # The id is load-bearing: the UA-detection script opens sections by id.
    assert f'id="{os_id}"' in HTML


def test_trust_vs_install_caveat_present():
    assert "Installing the certificate is not enough" in HTML


def _section(os_id):
    # Slice the HTML for one OS <details> block: from its id to the next
    # section id (the OS sections appear in source order macos→ios→android→
    # linux→windows). Lets a test assert what a given section links to.
    order = ["macos", "ios", "android", "linux", "windows"]
    start = HTML.index(f'id="{os_id}"')
    nxt = order[order.index(os_id) + 1] if os_id != order[-1] else None
    end = HTML.index(f'id="{nxt}"') if nxt else len(HTML)
    return HTML[start:end]


def test_ios_leads_with_mobileconfig():
    # iOS is the only Apple platform where the profile helps — it has a
    # Certificate Trust Settings toggle and avoids the Files-app routing (#169).
    assert 'href="/ca/halos-ca.mobileconfig"' in _section("ios")


def test_macos_uses_raw_crt_not_profile():
    # A profile-delivered root is not added to Keychain Access on macOS and has
    # no SSL-trust UI there, so macOS must use the raw .crt + Keychain path and
    # must NOT offer the .mobileconfig.
    macos = _section("macos")
    assert 'href="/ca/halos-ca.crt"' in macos
    assert "Always Trust" in macos
    assert "halos-ca.mobileconfig" not in macos


def test_ios_bare_crt_demoted_to_advanced():
    # The corrected raw-.crt fallback survives on iOS, inside an Advanced
    # disclosure rather than as the primary path.
    assert "Advanced: install the raw certificate instead" in _section("ios")


def test_ios_advanced_names_files_app_fallback():
    # #169: a raw .crt on iOS lands in Files; the fallback must say so instead
    # of the old (wrong) "Profile Downloaded" claim for the bare cert.
    assert "Files" in HTML


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

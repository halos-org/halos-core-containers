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


# --- Device-specific download filename + on-page device name ---------------
# These guard the structural invariants; the actual hostname value is filled at
# runtime from window.location.hostname, so it can't be asserted statically.

def test_cert_url_path_unchanged():
    # Only the saved filename becomes device-specific; the URL path the tile,
    # docs, and Traefik routing depend on must not move.
    assert 'href="/ca/halos-ca.crt"' in HTML


def test_cert_download_anchors_have_download_attr():
    # Every cert anchor keeps a static download attribute (a sensible fallback);
    # the device-specific name itself is set server-side via Content-Disposition,
    # not here (a server filename overrides the download attribute).
    import re

    cert_anchors = re.findall(r"<a\b[^>]*>", HTML)
    cert_anchors = [a for a in cert_anchors if 'href="/ca/halos-ca.crt"' in a]
    assert cert_anchors, "expected at least one cert-download anchor"
    for a in cert_anchors:
        assert "download=" in a


def test_device_host_placeholder_present():
    # At least one runtime-filled device-name slot exists.
    assert "data-device-host" in HTML


def test_instruction_filenames_are_templated():
    # Every visible reference to the downloaded file is hooked so the JS can
    # rewrite it to the device-specific name (matching the server-set save
    # name). The static text stays halos-ca.crt as the no-JS fallback.
    assert "data-cert-filename" in HTML
    # The Linux cp command references the file twice — both must be hooked, so
    # a copy-pasted command names the file the user actually downloaded.
    assert HTML.count("data-cert-filename") >= 2
    # The JS derives the same halos-ca-<host>.crt name the CGI does.
    assert 'halos-ca-" + safe + ".crt' in HTML


def test_device_name_falls_back_for_ip_access():
    # The CA's CN embeds a DNS hostname, never an IP, so the on-page device
    # name must fall back to "this device" when accessed by a raw IP.
    assert '"this device"' in HTML
    assert "isIp" in HTML


def test_trust_store_search_term_stable_for_old_certs():
    # Instructions anchor on the stable "HaLOS Device CA" prefix so a generic
    # (pre-feature, bare-CN) certificate is still findable in the trust store.
    assert "HaLOS Device CA" in HTML

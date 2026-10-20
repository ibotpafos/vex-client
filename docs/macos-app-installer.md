# macOS app-only graphical installer

The installer packages an existing, immutable signed ZIP rather than rebuilding
or re-signing VEX. Use the accepted archive SHA-256 and application certificate
SHA-256 from release evidence. Stock Apple `pkgbuild` and `productbuild` require
no additional dependencies. Run preparation through the maintained VEX MCP
`macos_release` installer phase, with a private source-bound request on D.

The user opens the PKG and confirms installation in macOS Installer. The package
installs to `~/Applications/VEX Native.app` in the current-user domain, without
administrator authorization. Its postinstall verifies both architecture code
hashes, bundle identity and version before removing quarantine from that app
copy only. It does not change certificate trust or global Gatekeeper settings.

The package does not install or restart a privileged helper, launch VEX, modify
VPN configuration, or disconnect a tunnel. It refuses to replace an app in use,
follow an installation-directory symlink, or downgrade an installed version.
An old manual 0.1.87 build132 may upgrade to 0.1.90 build120 because marketing
versions are compared before build numbers.

## First opening the installer

This is still self-signed app distribution, **not a notarized installer**. The
PKG itself is unsigned. On a clean Mac, Gatekeeper can require an initial
exception in System Settings → Privacy & Security → Open Anyway, before the
Installer opens. No Terminal command is needed, but one total confirmation on
every Mac is not promised. Managed Macs can prohibit such exceptions.

Apple changed the Control-click override in
[macOS Sequoia](https://developer.apple.com/news/?id=saqachfa). See Apple's
[manual app approval](https://support.apple.com/ru-ru/102445) and
[home-domain Installer behavior](https://developer.apple.com/library/archive/documentation/DeveloperTools/Reference/DistributionDefinitionRef/Chapters/Distribution_XML_Ref.html).

The app's existing Sparkle signature/key and immutable ZIP remain unchanged.
Publishing this additional package must not overwrite an immutable release or
replace Sparkle's ZIP enclosure with a PKG.

## Verification

`python3 -m unittest discover -s scripts/tests -p test_macos_app_installer.py`
executes the actual package scripts against disposable signed fixture apps.
It checks quarantine removal scope, tampered/differently signed code rejection,
symlink rejection, version compatibility and downgrade prevention. It does not
run an app or invoke Installer installation. Use a clean isolated macOS guest
for downloaded-PKG first-open and full graphical install acceptance; the host's
existing security override must not be counted as clean Gatekeeper acceptance.

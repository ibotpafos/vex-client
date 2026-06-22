# Security

Report security issues privately. Do not open public GitHub issues for vulnerabilities, leaked credentials, signing keys, updater bypasses, or production endpoint abuse.

This public client repository must not contain:

- VEX admin tokens or production API credentials
- Tauri updater private keys
- Authenticode certificates or passwords
- backend, admin, infrastructure, Ansible, Kamal, database, or deployment configuration
- production download artifacts copied from private infrastructure

The public workflow is allowed to build and publish GitHub Release artifacts only. Production updater promotion must happen from the private VPN repository after artifact verification.

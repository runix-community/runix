# Security

Runix has no stable security-supported release yet. Do not rely on it for
production systems or sensitive workloads.

Report vulnerabilities using GitHub's private vulnerability reporting feature
if enabled. Do not publish credentials or exploit details in a public issue.
If private reporting is unavailable, open an issue requesting a private contact
without disclosing the vulnerability details.

Nix expressions, derivations, and store outputs are not secret storage. Use
runtime `passwordHashFile` paths for password provisioning. Never commit guest
disk images, real password hashes, private keys, or generated secret files.

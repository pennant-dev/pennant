# Security

Pennant runs agents that can operate your Mac, read your files and act on your accounts, so security reports matter more than most. Thank you for looking.

## Reporting a vulnerability

Please report it privately:

- Use GitHub's **Report a vulnerability** button on the repository's Security tab (private vulnerability reporting), or
- email **security@pennant.dev**.

Include what you found, how to reproduce it, and what an attacker could do with it. Please don't open a public issue or discuss it publicly until a fix is out.

You'll get an acknowledgement within a few days. We'll keep you posted while we work on a fix, and credit you in the release notes if you'd like.

## Scope

In scope: the host (`pennant-host`), the Mac and iPhone apps, the `pennant` command-line client, and the protocol between them. That includes:

- ways to run tools or send, post or deploy without the user's approval
- prompt-injection paths that bypass approval cards or leak secrets from the vault
- pairing and authentication flaws in the local API, and secret handling in the Keychain and fallback files

Out of scope: vulnerabilities in third-party MCP servers, skills you install from elsewhere, or model providers, though we still want to hear about them if Pennant makes them worse.

## Supported versions

Only the latest release gets security fixes while the project is young.

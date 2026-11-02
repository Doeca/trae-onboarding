# Repository guidance

- API-only enterprise onboarding. Use native `magpie plugin login trae-cn`; never operate a browser or use the historical login helper.
- Bash entry point: `bash onboarding.sh`; setup is interactive `bootstrap`, offline readiness is `doctor`. Bash runtime uses curl/jq/GPG without Python and v2 state; the Python implementation and its tests have been removed. Bash tests: `bash tests/shell/run.sh`. Never auto-import Python v1 state or silently pick install/config paths.
- Ordinary tests are offline: `bash tests/shell/run.sh`. Do not run live `check`/`run` merely to inspect the project. Creating real members, inference, or altering live gateway settings requires authorization.
- All temporary artifacts and runtime journals belong under `./tmp`. Never commit `.env`, credentials, gateway keys, runtime state or raw HARs. Use synthetic fixtures, not captured credentials.
- Read `README.md` and `docs/USAGE.md` for supported parameters and known limitations. Installed Magpie is external; inspect the actual native contract before relying on undocumented fields.
- Administrator/member sessions remain isolated. Unknown invitation/registration/account-write outcomes must be reconciled before retries. A gateway or publication failure must not repeat completed member activation.
- Gateway secrets are output only to the caller's local controlling terminal. Never send keys, credential acquisition details, or local directory information to Lark groups. Preserve bridge environment variables; never unset them to bypass the terminal restriction.
- Do not claim successful inference or unattended renewal from native login, model listing or gateway configuration alone. No paid inference in ordinary validation.
- Follow inherited workspace instructions, including restrictions on skill rule disclosure.

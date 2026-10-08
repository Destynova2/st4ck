# Repository activation is an explicit operator step after browser OAuth login.
# Run scripts/setup-woodpecker.py with a private personal-token file; see
# docs/how-to/woodpecker-activate.md. It validates the API identity, activates
# the repository by its discovered forge ID, and verifies the resulting state.
#
# Bootstrap completion does not establish CI readiness or a successful job.
# Do not restore the former cookie scraping, hard-coded repository IDs, or
# deployment-secret injection: the validation pipeline needs no such secrets.

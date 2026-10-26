# K9OGate Swift SDK — Changelog

## 1.3.0 — 2026-10-26

### Changed

- `refreshToken(refreshToken:)` takes only the refresh token and returns a `K9ORefreshResult` with `accessToken` and `expiresAt`.
- `refreshToken` no longer replaces the stored refresh token. The gateway does not rotate it.
- `signOut(refreshToken:)` returns a `Bool`: `true` when a live session was revoked.
- `customClaims` returns the flat `ext.<namespace>.<name>` keys of the token.
- Response fields are read as the gateway sends them (camelCase).

### Removed

- The `projectHint` argument of `refreshToken`. The gateway rejects it.

### Added

- `K9ORefreshResult`.
- `K9OAccessToken.customClaim(namespace:name:)` reads one custom claim.


## 1.2.0 — 2026-10-25

- The README now introduces the Kilimanjaro products (Keep, Pulse, Gate, Kibo). No change to the public API.

## 1.1.1 — 2026-10-25

- Documentation links corrected: the documentation hub is https://docs.kilimanjaro.dev, with the website, platform API and console listed in a Links section. Package metadata points at the same places.

## 1.1.0 — 2026-10-25

- Documentation rewritten with runnable examples and expected output; internal cross-references removed from the published sources. No change to the public API.

## 1.0.0 — 2026-10-23

First public release. See the README for the full API overview.

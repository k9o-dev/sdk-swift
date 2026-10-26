# K9OGate

Swift SDK for Kilimanjaro Gate: sign end users in, refresh their access token and sign them out on iOS and macOS.

Kilimanjaro is the AI-native foundation for building critical applications.
Its products are Keep (AI Security and Governance), Pulse (Data Intelligence),
Gate (Customer Identity and Access Management) and Kibo (Keys and Secrets Management).

## Contents

- [Links](#links)
- [Install](#install)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Refresh and sign out](#refresh-and-sign-out)
- [Keychain storage](#keychain-storage)
- [Handle errors](#handle-errors)
- [Read token claims](#read-token-claims)
- [K9OCore](#k9ocore)
- [Appendix](#appendix)

## Links

- Website: <https://kilimanjaro.dev>
- Documentation / Developer Hub: <https://docs.kilimanjaro.dev>
- Platform API: <https://api.k9o.io>
- Platform Console: <https://console.k9o.io>

## Install

Add the package with Swift Package Manager.

```swift
dependencies: [
    .package(url: "https://github.com/k9o-dev/sdk-swift.git", from: "1.3.0"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "K9OGate", package: "sdk-swift"),
        ]
    ),
]
```

The package has two products, `K9OGate` and `K9OCore`. Add only the ones you use.

In Xcode, choose File > Add Package Dependencies and enter the same URL.

## Requirements

- iOS 15 or later, or macOS 12 or later
- Swift 5.9 or later
- No third-party dependencies

## Quick start

The examples sign in an end user of a project called `tasks-app`, which belongs to the organization `acme`.

```swift
import K9OGate

let orgURL = URL(string: "https://acme.api.k9o.io")!
let gate = GateClient(orgBaseURL: orgURL, projectSlug: "tasks-app")

let result = try await gate.signIn(email: "ada@example.com", password: "a-strong-password")

print("Signed in as \(result.user.email) (\(result.user.id))")
print("Access token expires at \(result.session.expiresAt)")
```

```text
Signed in as ada@example.com (eu_...)
Access token expires at 2026-01-01T12:00:00Z
```

`orgBaseURL` is your organization's API host. `signIn` saves the refresh token in the Keychain for you.

See all [client options](#client-options).

## Refresh and sign out

With no argument, `refreshToken()` uses the stored refresh token and returns a new access token.
The refresh token itself is not replaced: it stays valid until you sign out.

```swift
let refreshed = try await gate.refreshToken()

print("New access token expires at \(refreshed.expiresAt)")
```

```text
New access token expires at 2026-01-01T13:00:00Z
```

`signOut()` revokes the session and deletes the stored refresh token. It returns `true` when a live session was revoked.

```swift
let revoked = try await gate.signOut()

print("Revoked: \(revoked)")
```

```text
Revoked: true
```

See all [methods](#methods).

## Keychain storage

The refresh token is saved with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
It is not synced to iCloud or moved to a new device.

To manage tokens yourself, turn storage off with `tokenStore: nil`.
Then pass the refresh token to `refreshToken(refreshToken:)` and `signOut(refreshToken:)`.
The `signIn` result holds it in `result.session.refreshToken`.

```swift
let gate = GateClient(orgBaseURL: orgURL, projectSlug: "tasks-app", tokenStore: nil)
```

## Handle errors

Every call throws `K9OGateError`. Catch the cases you care about.

```swift
do {
    _ = try await gate.signIn(email: "ada@example.com", password: "wrong-password")
} catch K9OGateError.invalidCredentials {
    print("Wrong email or password.")
} catch K9OGateError.network(let error) {
    print("Network problem: \(error.localizedDescription)")
} catch {
    print("Sign-in failed: \(error.localizedDescription)")
}
```

```text
Wrong email or password.
```

See all [error cases](#error-cases).

## Read token claims

`K9OAccessToken.decode` reads an access token on the device. It does not verify the signature, so do not use it for security decisions.

Custom claims are flat keys of the form `ext.<namespace>.<name>`. `customClaim(namespace:name:)` reads one of them.

```swift
if let token = K9OAccessToken.decode(result.session.accessToken) {
    let role = token.customClaim(namespace: "partners", name: "partner_role") as? String
    print("Partner role: \(role ?? "none")")
}
```

```text
Partner role: extension_org_admin
```

`customClaims` returns every `ext.` claim, keyed by its full name, for example `ext.partners.partner_role`.

## K9OCore

The second product, `K9OCore`, is a project-plane client with one call today, `ai.embed`.

```swift
import K9OCore

let core = K9OCoreClient(baseURL: orgURL, projectSlug: "tasks-app", accessToken: accessToken)
let response = try await core.ai.embed(input: .one("Write the README"))
let vectors = response.data.embeddings
```

The platform rejects an end user's token for this call. Use the token of a project member or an extension.

See [related packages](#related-packages).

## Appendix

### Client options

`GateClient(orgBaseURL:projectSlug:tokenStore:urlSession:)`

| Option | Meaning |
|---|---|
| `orgBaseURL` | Your organization's API host, for example `https://acme.api.k9o.io` |
| `projectSlug` | The project's slug |
| `tokenStore` | A `KeychainTokenStore`; default is Keychain storage, `nil` turns storage off |
| `urlSession` | The `URLSession` to use; default is `URLSession.shared` |

`KeychainTokenStore(service:account:)` lets you choose the Keychain service and account names.

### Methods

| Method | Meaning |
|---|---|
| `signIn(email:password:)` | Sign in; returns `K9OAuthResult` |
| `refreshToken(refreshToken:)` | Get a new access token; returns `K9ORefreshResult` |
| `signOut(refreshToken:)` | End the session; returns `true` when a live session was revoked |
| `K9OAccessToken.decode(_:)` | Read a token's claims on the device |
| `customClaim(namespace:name:)` | One `ext.<namespace>.<name>` claim, or `nil` |

### Types

| Type | Fields |
|---|---|
| `K9OAuthResult` | `user`, `session` |
| `K9OEndUser` | `id`, `email`, `status`, `createdAt`, `updatedAt`, `lastSigninAt`, `roles`, `groups` |
| `K9OSession` | `accessToken`, `refreshToken`, `expiresAt` |
| `K9ORefreshResult` | `accessToken`, `expiresAt` |
| `K9OAccessToken` | `subject`, `issuer`, `expiresAt`, `issuedAt`, `allClaims`, `customClaims` (flat `ext.` keys) |

### Error cases

| Case | Meaning |
|---|---|
| `.invalidCredentials` | The email or password did not match |
| `.unauthenticated` | The session is missing, expired or revoked, or no refresh token is stored |
| `.forbidden` | The session may not perform this operation |
| `.network(Error)` | The request failed in transit |
| `.decoding(Error)` | The response was not in the expected shape |
| `.unknown(statusCode:body:)` | Any other non-2xx response, with the status and raw body |

### Related packages

| Product | What it does |
|---|---|
| `K9OGate` | Sign-in, refresh and sign-out (this page) |
| `K9OCore` | Project-plane client with `ai.embed`, in the same Swift package |

## License

Apache-2.0 © Formelo Inc. See `LICENSE` and `NOTICE`.

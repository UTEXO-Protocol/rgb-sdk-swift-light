# SDK privacy declarations

The SDK packages its own `PrivacyInfo.xcprivacy` in every `RGBSDK.framework`
slice. `Scripts/verify-apple-consumer.sh` builds an independent iOS app archive
and verifies that Xcode has carried the unchanged SDK manifest into the app's
framework resource bundle. This is not App Store approval or a signed release.

## Required-reason APIs

The encrypted operation journal calls `fstat` and `fstatat` to check file size,
ownership, type and link count before reading private state. Native Rust standard
library archives also reference `stat`, `lstat` and `fstat`; dead stripping can
remove unused implementations, but packaging declares this category regardless.
No timestamp, inode, size or other file metadata is sent to the gateway.

The FileTimestamp reasons are `C617.1` for app/app-group container storage and
`3B52.1` for a dedicated directory to which the user has explicitly granted
access. Prefer the application-support directory inside the app container.
An application using external storage must obtain and maintain the operating
system's required access grant; passing an arbitrary filesystem path is not
user consent. The SDK does not enumerate unrelated files or request access to
them. It does not use metadata to fingerprint a device or person.

These purposes were checked against Apple's [required-reason API reference](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
and [SDK manifest requirement](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
on 2026-09-19. The wrapper-only reason `0A2A.1` is deliberately not used: journal
integrity is the SDK's own function, not a file-metadata wrapper for the app.

## Data sent to the selected wallet service

The library has no analytics, advertising or tracking integration and no
tracking domains. A configured service nevertheless receives wallet-linked
financial information for its core functionality: account extended public
keys/master fingerprint during registration and, for enabled wallet requests,
asset identifiers, amounts, recipients, invoices and signed transaction payloads.
The bearer credential links these requests to a gateway user. The manifest
therefore declares **UserID** and **OtherFinancialInfo**, linked to the user,
for AppFunctionality, with tracking false. It does not falsely claim that no
data leaves the device just because signing is local.

Seeds, mnemonic phrases and extended private keys are not sent to the gateway.
The SDK does not control operator retention, additional server logs, third-party
indexer/proxy policies, or an application's own telemetry. The deployer must
review those actual data flows and its app-level disclosures. The manifest
does not certify a gateway operator's legal compliance or privacy policy.

The archived consumer check confirms resource packaging and plist values; final
distribution must still inspect Xcode's aggregated privacy report and App Store
validation for the signed shipping application and its other dependencies.

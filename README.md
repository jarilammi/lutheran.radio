[![CodeQL](https://github.com/jarilammi/lutheran.radio/actions/workflows/codeql-analysis.yml/badge.svg)](https://github.com/jarilammi/lutheran.radio/actions/workflows/codeql-analysis.yml)

# Lutheran Radio

📱 [Available on the App Store](https://apps.apple.com/fi/app/lutheran-radio/id6738301787?l=fi)

Listen to Lutheran Radio on iOS.

## Localizations
<table style="border: none;">
<tr>
<td width="40%" style="border: none;">

The app is fully localized in the following languages:
- Danish (da)
- German (de)
- English (en)
- Estonian (et)
- Finnish (fi)
- Tornedalen Finnish (fit)
- Faroese (fo)
- Icelandic (is)
- Greenlandic (kl)
- Lithuanian (lt)
- Latvian (lv)
- Norwegian Bokmål (nb)
- Norwegian Nynorsk (nn)
- Polish (pl)
- Russian (ru)
- Northern Sami (se)
- Swedish (sv)

</td>
<td width="60%" style="border: none;">

![Geographic distribution of supported languages](docs/language-map.svg)

</td>
</tr>
</table>

## Local Development and Contributing

To ensure a smooth development experience, follow these steps before contributing:

1. **Verify Project Build:** Confirm the project builds successfully with: ```xcodebuild -scheme "Lutheran Radio" -sdk iphonesimulator18.2 -destination 'platform=iOS Simulator,OS=18.3.1,name=iPhone 16 Pro' clean build```
   Ensure the output includes: **```** BUILD SUCCEEDED **```**

2. **Run Test Suite:** Validate the test suite passes with: ```xcodebuild -scheme "Lutheran Radio" -sdk iphonesimulator18.2 -destination 'platform=iOS Simulator,OS=18.3.1,name=iPhone 16 Pro' clean test```
   Check that the output includes: **```** TEST SUCCEEDED **```**

By verifying these steps on your local machine, you'll help maintain a consistent development environment for the project.

### Troubleshooting

If you encounter build or test issues, try these steps:

1. **Set Xcode Path:** If Xcode commands aren't found, run: ```sudo xcode-select -s /Applications/Xcode.app```
   Verify that your desired iPhone model is available with: ```xcrun simctl list```

2. **Clean Build Folder**: ```xcodebuild clean```

3. **Clean Derived Data**: This removes all derived data for all projects, so use with caution: ```rm -rf ~/Library/Developer/Xcode/DerivedData/*```

After cleaning, retry the build and test steps above.

# Security Implementation

## Certificate Pinning

The app implements certificate pinning to prevent man-in-the-middle (MITM) attacks. This is achieved by:

1. Generating a SHA-256 hash of the server's public key during development
2. Embedding this hash in the app's Info.plist file under NSAppTransportSecurity
3. Verifying the server's public key hash during each connection
4. Including subdomains in the pinning configuration

### Implementation Note

The app uses SHA-256 with Base64 encoding for certificate pinning, as specified in the Info.plist under `NSPinnedLeafIdentities`. This is a cryptographically secure choice for public key pinning because:

- SHA-256 provides sufficient collision resistance for this use case
- Fast hash computation is desirable since verification occurs on every connection
- The pinned value is a public key hash, not a password or sensitive data requiring slower hashing algorithms
- Base64 encoding ensures consistent representation across platforms

The configuration also:
- Applies to all subdomains of lutheran.radio (`NSIncludesSubdomains` set to true)
- Enforces a minimum TLS version of 1.3 (`NSTemporaryExceptionMinimumTLSVersion`)
- Requires forward secrecy (`NSTemporaryExceptionRequiresForwardSecrecy`)

### Verifying the Certificate Hash

To verify or update the certificate hash for lutheran.radio:

```bash
openssl s_client -connect livestream.lutheran.radio:8443 -servername livestream.lutheran.radio < /dev/null 2>/dev/null \
| openssl x509 -pubkey -noout \
| openssl pkey -pubin -inform pem -outform der \
| openssl dgst -sha256 -binary \
| base64
```

Compare the output to the value in Info.plist:

```
mm31qgyBr2aXX8NzxmX/OeKzrUeOtxim4foWmxL4TZY=
```

If the hash differs, update the SPKI-SHA256-BASE64 value in the Info.plist file accordingly.

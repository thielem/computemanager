# Releasing

Distribution: Homebrew cask `compute-manager` in tap `thielem/tap` (repo `thielem/homebrew-tap`),
zip attached to a GitHub release of `thielem/computemanager`. The owner lives in `GH_OWNER` at the
top of `scripts/release.sh`.

**Publishing requires Developer ID signing + notarization.** Ad-hoc builds are blocked by
Gatekeeper on other Macs and are for local testing only; `release.sh` warns when it makes one.

## Local test build (ad-hoc)

```sh
scripts/release.sh 0.1.0
```

Builds arm64 release binaries, assembles `dist/ComputeManager.app` (app + `fand` + `cgate`, fand
plist and install/uninstall scripts in `Resources`), zips to `dist/ComputeManager-0.1.0.zip`,
renders `packaging/homebrew/Casks/compute-manager.rb` with version + sha256, and prints the
publish commands without running them.

## One-time setup once the Developer ID arrives

1. Install the "Developer ID Application" certificate in the login keychain
   (`security find-identity -v -p codesigning`).
2. Store notary credentials (app-specific password from appleid.apple.com):
   ```sh
   xcrun notarytool store-credentials computemanager-notary \
     --apple-id <apple-id> --team-id <TEAMID> --password <app-specific-password>
   ```

## Release

```sh
export SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)"
export NOTARY_PROFILE=computemanager-notary
scripts/release.sh 0.2.0
```

Nested executables and the app get `--options runtime --timestamp` (no entitlements needed), the
zip is notarized, the app stapled and re-zipped. Then run the printed `gh release create …` and
commit `packaging/homebrew/Casks/compute-manager.rb`.

## Tap (first time)

```sh
gh repo create thielem/homebrew-tap --public
gh repo clone thielem/homebrew-tap ../homebrew-tap
```

Each release: copy the rendered cask to `../homebrew-tap/Casks/`, commit, push (commands are
printed by `release.sh`).

## Test install (clean user account)

```sh
brew install --cask thielem/tap/compute-manager   # asks for sudo: installs fand
open -a ComputeManager && cgate status
brew uninstall --cask --zap compute-manager       # removes fand, fans back to Auto
```

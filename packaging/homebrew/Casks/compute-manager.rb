cask "compute-manager" do
  version "0.1.0"
  sha256 "5947b457d9d91ac373308871ee482a239e67ef6df4ef8937836101b12f9243f9"

  url "https://github.com/thielem/computemanager/releases/download/v#{version}/ComputeManager-#{version}.zip"
  name "Compute Manager"
  desc "Menu bar gate for heavy agent jobs and fan control"
  homepage "https://github.com/thielem/computemanager"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "ComputeManager.app"
  # Runs before `app` is moved, so the path is inside the staged bundle (copies fand out of it).
  installer script: {
    executable: "ComputeManager.app/Contents/Resources/install-fand.sh",
    sudo:       true,
  }
  binary "#{appdir}/ComputeManager.app/Contents/MacOS/cgate"

  # Order is fixed by Homebrew: launchctl, quit, script, delete; all before the app is removed.
  uninstall launchctl: "com.moritzthiele.cgate.fand",
            quit:      "com.moritzthiele.cgate",
            script:    {
              executable: "#{appdir}/ComputeManager.app/Contents/Resources/uninstall-fand.sh",
              sudo:       true,
            },
            delete:    [
              "/Library/LaunchDaemons/com.moritzthiele.cgate.fand.plist",
              "/usr/local/libexec/computemanager",
              "/var/log/computemanager-fand.log",
              "/var/run/computemanager",
            ]

  zap trash: [
    "~/Library/Application Support/ComputeManager",
    "~/Library/Logs/ComputeManager",
    "~/Library/Preferences/com.moritzthiele.cgate.plist",
  ]

  caveats <<~EOS
    Fans revert to Auto when Compute Manager quits.
    Claude Code plugin:
      claude plugin marketplace add thielem/computemanager
      claude plugin install compute-gate@computemanager
  EOS
end

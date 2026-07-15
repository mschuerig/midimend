# typed: strict
# frozen_string_literal: true

# The published copy lives in mschuerig/homebrew-tap as
# Formula/midimend.rb. On new releases: bump `url`, refresh `sha256`
# (curl -L <url> | shasum -a 256), and copy to the tap.
class Midimend < Formula
  desc "Mend your MIDI before the DAW sees it"
  homepage "https://github.com/mschuerig/midimend"
  url "https://github.com/mschuerig/midimend/releases/download/v0.3.0/midimend-v0.3.0-macos.zip"
  sha256 "c14a8b93b85e70096fb8af32d347cf2c5702cfce33fc84984f16b2a4e2deca13"
  license :public_domain

  head do
    url "https://github.com/mschuerig/midimend.git", branch: "main"
    depends_on xcode: ["16.0", :build]
  end

  depends_on macos: :ventura

  def install
    if build.head?
      system "swift", "build", "--disable-sandbox", "-c", "release"
      bin.install ".build/release/midimend"
      man1.install "packaging/midimend.1"
      zsh_completion.install "packaging/completions/_midimend"
      bash_completion.install "packaging/completions/midimend.bash" => "midimend"
    else
      # The release asset is the Developer-ID-signed, notarized universal
      # binary; installing it untouched preserves that signature.
      bin.install "midimend"
      man1.install "midimend.1"
      zsh_completion.install "completions/_midimend"
      bash_completion.install "completions/midimend.bash" => "midimend"
    end
    pkgshare.install "examples"
  end

  # Starts at login; `crashed: true` restarts after crashes but not after
  # deliberate exits (e.g. missing config), avoiding a respawn loop.
  # `:interactive` keeps launchd from putting the process in a background
  # tier, where Darwin coarsens timer leeway and scheduling — milliseconds
  # of jitter for a MIDI processor.
  service do
    run opt_bin/"midimend"
    keep_alive crashed: true
    process_type :interactive
    log_path var/"log/midimend.log"
    error_log_path var/"log/midimend.log"
  end

  def caveats
    <<~EOS
      Started without arguments (as `brew services start midimend` does),
      midimend reads ~/Music/Midimend/config.json. Generate a skeleton:
        midimend --init your-script.js > ~/Music/Midimend/config.json
      Example scripts: #{opt_pkgshare}/examples
    EOS
  end

  test do
    assert_match "usage:", shell_output("#{bin}/midimend --help")
  end
end

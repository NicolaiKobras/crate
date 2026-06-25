import Foundation
import AppKit

/// Launches an interactive shell inside a container using the user's default
/// terminal application. We write a tiny `.command` script and hand it to
/// `NSWorkspace.open(_:)`; macOS then opens it in whichever app the user has
/// associated with `.command` (Terminal.app by default, but iTerm2, Ghostty,
/// etc. honour the same hook).
enum NativeTerminal {
    static func openShell(containerId: String, shell: String = "/bin/sh") -> Error? {
        let stored = UserDefaults.standard.string(forKey: "containerBinaryPath")
        guard let binary = BinaryLocator.resolveContainerBinary(preferredPath: stored) else {
            return BackendError.binaryNotFound
        }
        // Re-verify right before launch: BinaryLocator already checks executability
        // at lookup time, but the file could have been replaced or chmod'd between
        // the AppStorage save and this call.
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            return BackendError.binaryNotFound
        }

        // Build a small shell script. We deliberately do NOT use `exec` so that
        // when `container exec` exits with an error (container not running,
        // missing shell binary, etc.) bash sticks around long enough to print
        // the status and let the user dismiss the window — otherwise Terminal
        // just shows a cryptic post-mortem prompt with the script path on it.
        //
        // Two subtleties on the error path:
        //   • `container exec -i -t` may leave the controlling terminal in raw /
        //     non-blocking mode on exit. `stty sane` puts it back so the read
        //     below blocks correctly.
        //   • Reading from `</dev/tty` bypasses stdin entirely (which may also
        //     be left in a strange state), so the prompt reliably waits for the
        //     user's Return.
        let script = """
        #!/bin/bash
        clear
        \(bashQuoted(binary)) exec -i -t \(bashQuoted(containerId)) \(bashQuoted(shell))
        status=$?
        if [ $status -ne 0 ]; then
          stty sane </dev/tty 2>/dev/null
          echo
          echo "── container exec exited with status $status ──"
          echo "Press Return to close."
          read -r _ </dev/tty
        fi
        """

        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crate-shell-\(UUID().uuidString).command")

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scriptURL.path
            )
        } catch {
            return error
        }

        if !NSWorkspace.shared.open(scriptURL) {
            return BackendError.commandFailed(
                command: "open .command",
                exit: -1,
                stderr: "Failed to launch terminal application."
            )
        }

        // We do NOT schedule a deletion. Each script is ~200 B; macOS purges
        // `/var/folders/.../T/` periodically. Deleting it ourselves risks racing
        // a slow Terminal launch and producing the confusing "command ; exit;"
        // empty-prompt that the user saw.
        return nil
    }

    /// Escape an arbitrary string into a bash-safe single-quoted literal.
    /// Single quotes inside the value are closed, escaped, and re-opened.
    private static func bashQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

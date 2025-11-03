import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let alert = NSAlert()
        alert.messageText = "OneFiler Host App"
        alert.informativeText = """
        This app embeds the File Provider extension.

        To manage File Provider domains, use the CLI tool:
          onefiler register --name <name> --path <instance-path>
          onefiler unregister --name <name>
          onefiler list

        The extension will be automatically loaded by macOS when domains are registered.
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()

        NSApplication.shared.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

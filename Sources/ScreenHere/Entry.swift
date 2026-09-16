import Foundation

/// The process entry point. Almost always it just starts the app; launched
/// with the reader argument it is ScreenHere's text reader service, and it
/// must never bring up the app itself — no menu-bar icon, no hotkey takeover,
/// no second instance.
@main
enum Entry {
    static func main() {
        switch CommandLine.arguments.dropFirst().first {
        case ReaderService.argument:
            exit(ReaderService.run(arguments: Array(CommandLine.arguments.dropFirst(2))))
        default:
            ScreenHereApp.main()
        }
    }
}

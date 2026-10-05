import Foundation

/// The process entry point. Almost always it just starts the app; launched
/// with a reader argument it reads text for the app and nothing else, and it
/// must never bring up the app itself — no menu-bar icon, no hotkey takeover,
/// no second instance.
@main
enum Entry {
    static func main() {
        switch CommandLine.arguments.dropFirst().first {
        case ReaderService.argument:
            exit(ReaderService.run(arguments: Array(CommandLine.arguments.dropFirst(2))))
        case FastReadService.argument:
            exit(FastReadService.run())
        default:
            ScreenHereApp.main()
        }
    }
}

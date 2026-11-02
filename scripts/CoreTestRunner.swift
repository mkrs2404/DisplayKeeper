import Testing

// This is the same Swift Testing entry point used by SwiftPM's generated runner.
@main
struct CoreTestRunner {
    static func main() async {
        await Testing.__swiftPMEntryPoint() as Never
    }
}

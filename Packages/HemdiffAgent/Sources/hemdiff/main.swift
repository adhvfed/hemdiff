import HemdiffAgentKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@main struct Hemdiff {
  static func main() async { exit(await Application.run(arguments: Array(CommandLine.arguments.dropFirst()))) }
}

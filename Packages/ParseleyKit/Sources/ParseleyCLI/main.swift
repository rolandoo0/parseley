import Foundation
import ParseleyTools

// `parseley`: the command-line front end. All logic lives in ParseleyTools.

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "mcp" {
    var rest = Array(arguments.dropFirst())
    var dbPath: String?
    if let i = rest.firstIndex(of: "--db"), i + 1 < rest.count {
        dbPath = rest[i + 1]
        rest.removeSubrange(i...(i + 1))
    }
    MCPServer(openToolbox: { try Toolbox.open(path: dbPath) }).serve()
    exit(0)
}

// Read piped input (e.g. `pbpaste | parseley sum`), but never wait on a terminal.
let piped: String? = isatty(fileno(stdin)) == 0
    ? String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)
    : nil

let output = CLI.run(arguments, stdin: piped)
if !output.stdout.isEmpty { print(output.stdout) }
if !output.stderr.isEmpty { FileHandle.standardError.write(Data((output.stderr + "\n").utf8)) }
exit(output.code)

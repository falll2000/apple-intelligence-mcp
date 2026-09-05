import Foundation

// main.swift is the top-level entry point, so @main cannot be used.
// Use Task + dispatchMain() to run the async program.

let mainTask = Task {
    await CoreService.run()
    // run() returns when stdin reaches EOF, i.e. the parent MCP server is gone.
    // dispatchMain() would otherwise keep this process alive forever as an orphan.
    exit(0)
}

dispatchMain() // Keep the process alive.

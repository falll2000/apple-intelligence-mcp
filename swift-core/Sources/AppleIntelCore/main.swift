import Foundation

// main.swift is the top-level entry point, so @main cannot be used.
// Use Task + dispatchMain() to run the async program.

let mainTask = Task {
    await CoreService.run()
}

dispatchMain() // Keep the process alive.

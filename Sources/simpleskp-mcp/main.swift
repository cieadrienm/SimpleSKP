import Foundation
import SimpleSKPMCPCore

let base = apiBaseURL()
let server = SimpleSKPMCPServer(transport: urlSessionTransport(base: base), apiBase: base)
server.run()

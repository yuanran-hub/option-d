import Foundation

func pythonProcess(resources: URL) -> Process {
    let process = Process()
    #if PORTABLE
    #if arch(arm64)
    let cpu = "aarch64"
    #else
    let cpu = "x86_64"
    #endif
    process.executableURL = resources.appendingPathComponent("runtime/\(cpu)/bin/python3.12")
    var environment = ProcessInfo.processInfo.environment
    for key in environment.keys.filter({ $0.hasPrefix("PYTHON") }) {
        environment.removeValue(forKey: key)
    }
    environment["PYTHONNOUSERSITE"] = "1"
    environment["SSL_CERT_FILE"] = "/etc/ssl/cert.pem"
    process.environment = environment
    #else
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    #endif
    return process
}

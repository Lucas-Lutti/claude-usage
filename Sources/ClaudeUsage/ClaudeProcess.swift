import AppKit
import Darwin

/// Detecta se o Claude está aberto: o app desktop ou o Claude Code (terminal, IDE ou dentro do app).
enum ClaudeProcess {
    static let desktopBundleID = "com.anthropic.claudefordesktop"

    static var isRunning: Bool { desktopRunning || codeRunning }

    static var desktopRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: desktopBundleID).isEmpty
    }

    /// O Claude Code roda como um processo chamado "claude".
    static var codeRunning: Bool {
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return false }
        var name = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(min(count, pids.count)) where pid > 0 {
            if proc_name(pid, &name, UInt32(name.count)) > 0, String(cString: name) == "claude" { return true }
        }
        return false
    }
}

import Darwin
import Foundation

/// Small wrapper around the BSD process table so we can find a process's parent
/// and short command name. Used to attribute helper/child processes (browser
/// media helpers, game subprocesses launched via Steam/Proton, …) to the real
/// app the user actually launched.
enum ProcessTree {
    /// Returns the parent PID and short command name for a process in one call,
    /// or `nil` if the process can't be inspected (gone, or not permitted).
    static func info(for pid: pid_t) -> (ppid: pid_t, command: String)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&mib, UInt32(mib.count), &kp, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }

        let ppid = kp.kp_eproc.e_ppid
        let command = withUnsafeBytes(of: kp.kp_proc.p_comm) { raw -> String in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        return (ppid, command)
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        info(for: pid)?.ppid
    }

    static func command(of pid: pid_t) -> String {
        info(for: pid)?.command ?? ""
    }
}

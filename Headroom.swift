// Headroom: a tiny menu bar app that answers "is my Mac fast or slow right now?"
// and shows which apps are to blame. Build with ./build.sh.
//
// Built to cost almost nothing: while the popover is closed it only reads a few
// kernel counters every 5 s. Per-app numbers come from libproc and Docker's own
// socket, and only while the popover is open. No child processes are spawned.

import SwiftUI
import Darwin
import ServiceManagement

let gb = 1_073_741_824.0
let home = NSHomeDirectory()

// A container engine: a Mac app that runs a Linux VM and speaks the Docker API
// over a unix socket. Docker Desktop and OrbStack both do.
struct Engine: Identifiable, Equatable {
    var id: String { name }
    let name: String  // also the app group name in the process list
    let appPath: String
    let socket: String
    // Docker's VM keeps memory its containers no longer use until Docker restarts.
    // OrbStack hands memory back to macOS on its own, so there is nothing to reclaim.
    let canReclaim: Bool
    let bundleID: String  // the running app that says the engine is up

    // Where the containers running at the last good scan are remembered.
    var lastContainersKey: String { self == .docker ? Pref.lastContainers : Pref.lastContainers + "." + name }

    static let docker = Engine(name: "Docker", appPath: "/Applications/Docker.app",
                               socket: home + "/.docker/run/docker.sock", canReclaim: true,
                               bundleID: "com.docker.docker")
    static let orbstack = Engine(name: "OrbStack", appPath: "/Applications/OrbStack.app",
                                 socket: home + "/.orbstack/run/docker.sock", canReclaim: false,
                                 bundleID: "dev.kdrag0n.MacVirt")
    static let known = [docker, orbstack]
}

// MARK: - Types

enum Verdict: Int, Comparable {
    case smooth, busy, slow

    static func < (a: Verdict, b: Verdict) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .smooth: return "Running smoothly"
        case .busy: return "A bit busy"
        case .slow: return "Slowing down"
        }
    }
    var symbol: String {
        switch self {
        case .smooth: return "checkmark.circle.fill"
        case .busy: return "exclamationmark.circle.fill"
        case .slow: return "exclamationmark.triangle.fill"
        }
    }
    // How full the menu bar capsule is, in points of its 18 pt glyph.
    var level: CGFloat {
        switch self {
        case .smooth: return 4
        case .busy: return 7.6
        case .slow: return 11.6
        }
    }
    var color: Color {
        switch self {
        case .smooth: return .green
        case .busy: return .orange
        case .slow: return .red
        }
    }
    var nsColor: NSColor {
        switch self {
        case .smooth: return .systemGreen
        case .busy: return .systemOrange
        case .slow: return .systemRed
        }
    }
}

// One process, described well enough to tell apart from its siblings: the
// script a Python runs, the folder a CLI tool runs in, what a helper does.
struct ProcUsage: Identifiable {
    var id: pid_t { pid }
    let pid: pid_t
    let label: String  // "serve.py", "headroom", "Web Content", "Helper (Renderer)"
    let detail: String?  // "~/Documents/Code/AI/workflows", nil for the app's main process
    let mb: Double
    let cpu: Double
}

// Processes of one app that share a label, as one row of the app's breakdown.
struct AppPart: Identifiable {
    var id: String { label }
    let label: String
    let detail: String?
    let mb: Double
    let cpu: Double
    let count: Int
}

struct AppUsage: Identifiable {
    var id: String { name }
    let name: String
    let bundlePath: String?  // the .app to take the icon from and to quit
    let mb: Double
    let cpu: Double  // percent of one core, summed over the app's processes
    let isSystem: Bool  // part of macOS, nothing to act on
    let procs: [ProcUsage]

    var count: Int { procs.count }

    // Same label -> one row, with a count. The detail stays only when every
    // process in the row agrees on it; otherwise it names the biggest one.
    var parts: [AppPart] {
        var order: [String] = []
        var by: [String: [ProcUsage]] = [:]
        for p in procs {
            if by[p.label] == nil { order.append(p.label) }
            by[p.label, default: []].append(p)
        }
        return order.map { label in
            let ps = by[label]!
            let details = Set(ps.compactMap(\.detail))
            let detail: String?
            if ps.count == 1 || details.count == 1 { detail = details.first }
            else { detail = "largest " + formatMB(ps.map(\.mb).max() ?? 0) }
            return AppPart(label: label, detail: detail, mb: ps.reduce(0) { $0 + $1.mb },
                           cpu: ps.reduce(0) { $0 + $1.cpu }, count: ps.count)
        }
    }

    // Worth expanding: more than one row, or one row that says something
    // beyond the app's own name.
    var hasBreakdown: Bool {
        procs.count > 1 || procs.first.map { $0.label != name || $0.detail != nil } ?? false
    }

    // Memory of the app's virtual machine processes, for container engines.
    var vmMB: Double { procs.filter { $0.label == ProcScanner.vmLabel }.reduce(0) { $0 + $1.mb } }
}

// Cheap system numbers, sampled every tick.
struct Sample {
    var pressure: Int32 = 1  // kernel level: 1 normal, 2 warn, 4 critical
    var memUsed = 0.0  // GB, the "Memory Used" Activity Monitor shows
    var total = 0.0  // GB
    var appMem = 0.0, wired = 0.0, compressed = 0.0  // GB, the parts of memUsed
    var swapUsed = 0.0  // GB
    var cpuTicks: (user: UInt64, system: UInt64, idle: UInt64) = (0, 0, 0)
    var thermal = ProcessInfo.ThermalState.nominal  // fair, serious, critical = throttling
}

struct Container: Identifiable {
    var id: String { engine + "/" + name }
    let engine: String  // Engine.name it runs under
    let name: String
    let image: String
    let project: String  // compose project, "" if none
    let port: Int?  // first published host port
    let uptime: String  // "8 days", "31 min"
    var cpu: Double? = nil  // percent of one core, like docker stats
    var mb: Double? = nil
    var restarting = false  // crash-looping under a restart policy

    // Databases and caches go first when starting things back up.
    var isInfra: Bool {
        ["postgres", "redis", "mysql", "mariadb", "mongo"].contains { image.hasPrefix($0) }
    }

    // "website-v2-web" -> "web": the project row already names the project.
    var shortImage: String {
        guard !project.isEmpty, image.hasPrefix(project + "-") else { return image }
        return String(image.dropFirst(project.count + 1))
    }
}

// CPU as a share of the whole Mac. libproc and docker stats count per core, so
// a busy app reads "815%"; everywhere on screen we show its share, "82%".
let coreCount = Double(ProcessInfo.processInfo.activeProcessorCount)
func cpuShare(_ perCore: Double) -> Double { min(perCore / coreCount, 100) }

func formatMB(_ mb: Double) -> String {
    // From 1000 MB up, GB reads better than "1010 MB".
    mb >= 1000 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
}

// MARK: - Settings

// UserDefaults keys. Views read them with @AppStorage; the model reads them directly.
enum Pref {
    static let menuText = "menuText"  // MenuText raw value
    static let appCount = "appCount"  // apps listed in the popover
    static let showDocker = "showDocker"
    static let lastContainers = "lastRunningContainers"  // offered back after Docker breaks
}

// What sits next to the capsule in the menu bar.
enum MenuText: String, CaseIterable {
    case none, memory, cpu

    var label: String {
        switch self {
        case .none: return "Icon only"
        case .memory: return "Icon and MEM %"
        case .cpu: return "Icon and CPU %"
        }
    }
}

enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

// MARK: - System sample (kernel counters, microseconds)

func sampleSystem() -> Sample {
    var s = Sample()
    s.total = Double(ProcessInfo.processInfo.physicalMemory) / gb

    var level: Int32 = 1
    var size = MemoryLayout<Int32>.size
    if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
        s.pressure = level
    }

    var swap = xsw_usage()
    size = MemoryLayout<xsw_usage>.size
    if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
        s.swapUsed = Double(swap.xsu_used) / gb
    }

    var vm = vm_statistics64()
    var count = mach_msg_type_number_t(
        MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &vm) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    if kr == KERN_SUCCESS {
        let page = Double(vm_kernel_page_size) / gb
        s.appMem = (Double(vm.internal_page_count) - Double(vm.purgeable_count)) * page
        s.wired = Double(vm.wire_count) * page
        s.compressed = Double(vm.compressor_page_count) * page
        s.memUsed = s.appMem + s.wired + s.compressed
    }

    var cpu = host_cpu_load_info()
    var cpuCount = mach_msg_type_number_t(
        MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
    let ckr = withUnsafeMutablePointer(to: &cpu) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) {
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &cpuCount)
        }
    }
    if ckr == KERN_SUCCESS {
        let t = cpu.cpu_ticks
        s.cpuTicks = (UInt64(t.0) + UInt64(t.3), UInt64(t.1), UInt64(t.2))  // user + nice, system, idle
    }
    s.thermal = ProcessInfo.processInfo.thermalState
    return s
}

// Free and total space on the startup disk, in GB as Finder counts them.
// "Important usage" includes space macOS can purge, which is what Finder shows.
func sampleDisk() -> (free: Double, total: Double)? {
    let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
    guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
          let free = v.volumeAvailableCapacityForImportantUsage, let total = v.volumeTotalCapacity
    else { return nil }
    return (Double(free) / 1e9, Double(total) / 1e9)
}

// MARK: - Per-app scan (libproc, ~3 ms for all processes)

// /Applications/Safari.app is a symlink into the Cryptex. Safari runs from the real path,
// and the link itself gets the alias icon with the shortcut arrow.
let safariBundle = ("/Applications/Safari.app" as NSString).resolvingSymlinksInPath

// Interpreters get one group each, whatever the binary is called: python3.12,
// Python (from Python.app inside a framework) and a venv's python are all Python.
func interpreterName(_ exe: String) -> String? {
    let e = exe.lowercased()
    if e.hasPrefix("python") { return "Python" }
    if e == "node" || e == "bun" || e == "deno" { return "Node.js" }
    if e == "ruby" { return "Ruby" }
    if e == "perl" { return "Perl" }
    if e == "java" { return "Java" }
    if e.hasPrefix("php") { return "PHP" }
    return nil
}

// Group helpers under their app: ".../Google Chrome.app/.../Helper" -> "Google Chrome".
func appGroup(_ path: String) -> (name: String, bundle: String?) {
    if path.hasSuffix("/claude") || path.contains("/claude/versions/") { return ("Claude Code", nil) }
    let exe = path.split(separator: "/").last.map(String.init) ?? path
    // Python.app inside Python.framework is still Python; "java" inside some
    // IDE's bundle is that IDE.
    if let name = interpreterName(exe), !path.contains(".app/") || path.contains("/Python.app/") {
        return (name, nil)
    }
    // Plain string slicing: URL(fileURLWithPath:) stats the disk to check for a directory.
    if let r = path.range(of: ".app/") {
        let bundle = String(path[..<r.lowerBound])
        let name = bundle.split(separator: "/").last.map(String.init) ?? bundle
        // Safari lives in a cryptex; the link in /Applications would show an alias icon.
        if name == "Safari" { return (name, safariBundle) }
        return (name, bundle + ".app")
    }
    return (exe, nil)
}

// What a process is, within its app. Worked out once per pid.
struct Owner {
    let name: String  // app group
    let bundle: String?
    let system: Bool
    let label: String
    let detail: String?
}

// Keeps the previous CPU times so each scan can turn them into a percentage.
// Only touched from Model's background queue.
final class ProcScanner: @unchecked Sendable {
    static let vmLabel = "Linux VM"

    private var lastCPU: [pid_t: UInt64] = [:]  // ns
    private var lastWall: UInt64 = 0  // ns
    // pid -> app it belongs to. Worked out once per process, not every scan.
    private var owners: [pid_t: Owner] = [:]
    // bundle path -> its CFBundleExecutable, to tell the main binary from siblings.
    private var mainExe: [String: String] = [:]
    private let ticksToNs: Double = {
        var tb = mach_timebase_info()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()
    private let systemDirs = ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/"]
    private var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)

    // The process that launched an XPC service or app extension, as Activity
    // Monitor groups them. Public in libSystem but not declared in any header.
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private let responsible: ResponsibleFn? = {
        dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid")
            .map { unsafeBitCast($0, to: ResponsibleFn.self) }
    }()

    // Processes owned by other users (WindowServer, daemons) can't be read
    // without root; they're macOS internals you couldn't quit anyway.
    func scan() -> [AppUsage] {
        let now = UInt64(Double(mach_absolute_time()) * ticksToNs)
        let wall = lastWall > 0 ? Double(now - lastWall) : 0
        lastWall = now

        let n = proc_listallpids(nil, 0)
        var pids = [pid_t](repeating: 0, count: Int(n) + 32)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))

        var cpuNow: [pid_t: UInt64] = [:]
        var seen: [pid_t: Owner] = [:]
        var order: [String] = []
        var groups: [String: (bundle: String?, system: Bool, procs: [ProcUsage])] = [:]

        for pid in pids.prefix(Int(max(got, 0))) where pid > 0 {
            var ri = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &ri) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard ok == 0 else { continue }

            let t = UInt64(Double(ri.ri_user_time + ri.ri_system_time) * ticksToNs)
            cpuNow[pid] = t
            var cpu = 0.0
            if wall > 0, let prev = lastCPU[pid], t >= prev { cpu = Double(t - prev) / wall * 100 }
            let mb = Double(ri.ri_phys_footprint) / 1_048_576
            guard mb >= 1 || cpu > 0 else { continue }

            guard let owner = owners[pid] ?? describe(pid) else { continue }
            seen[pid] = owner

            if groups[owner.name] == nil {
                order.append(owner.name)
                groups[owner.name] = (owner.bundle, true, [])
            }
            groups[owner.name]!.procs.append(ProcUsage(pid: pid, label: owner.label, detail: owner.detail,
                                                       mb: mb, cpu: cpu))
            groups[owner.name]!.system = groups[owner.name]!.system && owner.system
            if groups[owner.name]!.bundle == nil { groups[owner.name]!.bundle = owner.bundle }
        }
        lastCPU = cpuNow
        owners = seen  // drops exited pids, so a reused pid gets looked up again

        return order.map { name in
            let g = groups[name]!
            // Biggest first, so the breakdown reads top-down like the app list.
            let procs = g.procs.sorted { $0.mb > $1.mb }
            return AppUsage(name: name, bundlePath: g.bundle, mb: procs.reduce(0) { $0 + $1.mb },
                            cpu: procs.reduce(0) { $0 + $1.cpu }, isSystem: g.system, procs: procs)
        }
    }

    private func exePath(_ pid: pid_t) -> String? {
        proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    // MARK: Describing a process

    private func describe(_ pid: pid_t) -> Owner? {
        guard let path = exePath(pid) else { return nil }
        let exe = path.split(separator: "/").last.map(String.init) ?? path
        var (name, bundle) = appGroup(path)

        // XPC services and extensions run from /System or their own bundle, but
        // belong to whoever launched them: Safari's tabs, Docker's VM, Chrome's
        // extensions. Only those; a CLI tool is not "part of" the terminal.
        let isService = path.contains(".xpc/") || path.contains(".appex/")
        var host = ""
        var hostLS = ""
        var base = path
        if isService, let r = responsible?(pid), r != pid, let hostPath = exePath(r) {
            let (hostName, hostBundle) = appGroup(hostPath)
            if hostBundle != nil {
                (name, bundle, host, base) = (hostName, hostBundle, hostName, hostPath)
                hostLS = NSRunningApplication(processIdentifier: r)?.localizedName ?? ""
            }
        }

        // Apple's own user-facing apps (Safari, Mail) are quittable like any other.
        // A hosted helper counts as system or not by its host, so Finder stays system.
        let system = systemDirs.contains { base.hasPrefix($0) } && !base.contains("/Applications/")

        let (label, detail) = describeProcess(pid: pid, path: path, exe: exe, app: name, host: host, hostLS: hostLS)
        return Owner(name: name, bundle: bundle, system: system, label: label, detail: detail)
    }

    private func mainExecutable(of bundle: String) -> String {
        if let e = mainExe[bundle] { return e }
        let e = Bundle(path: bundle)?.executableURL?.lastPathComponent
            ?? bundle.split(separator: "/").last.map { String($0.dropLast(4)) } ?? ""
        mainExe[bundle] = e
        return e
    }

    // The label tells siblings apart; the detail says where or what.
    private func describeProcess(pid: pid_t, path: String, exe: String, app: String, host: String, hostLS: String)
        -> (String, String?)
    {
        let args = arguments(of: pid)

        if path.contains("Virtualization.VirtualMachine") || (app == "OrbStack" && args.dropFirst().first == "vmgr") {
            return (Self.vmLabel, nil)
        }

        // Scripts: "python -u serve.py --flag" -> "serve.py" in its folder.
        // npm and friends overwrite argv with a title ("npm exec foo"); use it.
        if interpreterName(exe) != nil {
            let title = args.first.flatMap { $0.contains(" ") ? $0 : nil }
            return (scriptName(args) ?? title ?? exe, folder(of: pid, fallback: args))
        }

        // An app's own main executable. Siblings beside it (crash handlers,
        // plugin hosts) fall through and show by their own name.
        if let r = path.range(of: ".app/Contents/MacOS/"), !path[r.upperBound...].contains("/"),
           !path[..<r.lowerBound].contains(".app/"), host.isEmpty,
           exe == mainExecutable(of: String(path[..<r.lowerBound]) + ".app") {
            return (app, nil)
        }

        // Helpers inside the bundle, and services the app launched. Launch
        // Services knows a better name for some: "Safari Web Content",
        // "Safari Service Worker (youtube.com)", "Grammarly Web Extension".
        if path.contains(".app/") || path.contains(".xpc/") || path.contains(".appex/") || !host.isEmpty {
            var label = exe
            if path.contains(".xpc/"), let ls = NSRunningApplication(processIdentifier: pid)?.localizedName,
               !ls.isEmpty {
                label = ls
            }
            if label.hasPrefix("com.apple.") { label = String(label.dropFirst("com.apple.".count)) }
            for prefix in [app + " ", host + " "] where prefix.count > 1 && label.hasPrefix(prefix) {
                label = String(label.dropFirst(prefix.count))
            }
            // Apple's shared services put the host at the end instead:
            // "Open and Save Panel Service (CLion)", "AutoFill (iTerm2)".
            for suffix in [app, host, hostLS].map({ " (\($0))" }) where suffix.count > 3 && label.hasSuffix(suffix) {
                label = String(label.dropLast(suffix.count))
            }
            return (label, nil)
        }

        // Command-line tools: the folder they run in is what tells them apart.
        // "claude" in ~/Downloads/headroom is the session on that project.
        // A sandbox container is no project folder.
        if let dir = folder(of: pid, fallback: []), dir != "/", dir != "~", !dir.hasPrefix("~/Library/Containers/") {
            return (dir.split(separator: "/").last.map(String.init) ?? exe, dir)
        }
        return (exe, nil)
    }

    // The first argument that isn't an option: "python -u serve.py" -> "serve.py",
    // "python -m http.server" -> "http.server". Every project has an index.js
    // or main.py, so those carry the first folder that says something.
    private func scriptName(_ args: [String]) -> String? {
        var rest = args.dropFirst()
        while let a = rest.first {
            rest = rest.dropFirst()
            if a == "-m" || a == "--module" { return rest.first }
            if a == "-c" || a == "-e" { return nil }
            if a.hasPrefix("-") || a.isEmpty { continue }
            let parts = a.split(separator: "/").map(String.init)
            guard let file = parts.last else { return nil }
            let generic = ["index.js", "index.mjs", "index.cjs", "main.js", "server.js", "cli.js", "app.js",
                           "main.py", "__main__.py", "app.py", "run.py", "server.py", "manage.py", "cli.py"]
            let noise = ["src", "dist", "lib", "bin", "build", "out", "scripts", "node_modules", ".bin"]
            guard generic.contains(file),
                  let dir = parts.dropLast().last(where: { !noise.contains($0) }) else { return file }
            return dir + "/" + file
        }
        return nil
    }

    // Working directory with ~ for home; the script's folder when the process
    // runs from / (launchd jobs do).
    private func folder(of pid: pid_t, fallback args: [String]) -> String? {
        var vi = proc_vnodepathinfo()
        let n = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vi, Int32(MemoryLayout<proc_vnodepathinfo>.size))
        var dir = n > 0 ? withUnsafePointer(to: &vi.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        } : ""
        if dir == "/" || dir.isEmpty, let script = args.dropFirst().first(where: { $0.hasPrefix("/") }) {
            dir = script.split(separator: "/").dropLast().reduce("") { $0 + "/" + $1 }
        }
        guard !dir.isEmpty else { return nil }
        if dir.hasPrefix(home) { dir = "~" + dir.dropFirst(home.count) }
        return dir
    }

    // argv, readable for our own processes. Layout: argc, exec path, NULs, argv...
    private func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var raw = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &raw, &size, nil, 0) == 0 else { return [] }
        let argc = Int(raw.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size && raw[i] != 0 { i += 1 }  // exec path
        while i < size && raw[i] == 0 { i += 1 }  // padding
        var args: [String] = []
        var cur: [UInt8] = []
        while i < size && args.count < argc {
            if raw[i] == 0 { args.append(String(decoding: cur, as: UTF8.self)); cur = [] }
            else { cur.append(raw[i]) }
            i += 1
        }
        return args
    }
}

// MARK: - Docker API (over an engine's unix socket, no CLI)

enum Docker {
    // Minimal HTTP/1.1 + Connection: close over the socket; stops at Content-Length or the final chunk and dechunks.
    static func request(_ engine: Engine, _ method: String, _ path: String, timeout: Int = 3) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(engine.socket.utf8.prefix(MemoryLayout.size(ofValue: addr.sun_path) - 1))
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        // Docker Desktop closes after one HTTP/1.0 response. OrbStack's socket
        // answers HTTP/1.1 with chunked encoding and keeps the connection open
        // regardless, so stop at the final chunk (or Content-Length) and dechunk.
        let req = "\(method) \(path) HTTP/1.1\r\nHost: docker\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
        guard req.withCString({ write(fd, $0, strlen($0)) }) > 0 else { return nil }

        let crlf2 = Data("\r\n\r\n".utf8)
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        var head: String?
        var bodyStart = 0
        var chunked = false
        var length: Int?
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
            if head == nil, let split = data.range(of: crlf2) {
                head = String(decoding: data[..<split.lowerBound], as: UTF8.self)
                bodyStart = split.upperBound
                for line in head!.split(separator: "\r\n") {
                    let l = line.lowercased()
                    if l.hasPrefix("transfer-encoding:") && l.contains("chunked") { chunked = true }
                    if l.hasPrefix("content-length:") {
                        length = Int(l.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
                    }
                }
            }
            guard head != nil else { continue }
            if chunked, data.suffix(5) == Data("0\r\n\r\n".utf8) { break }
            if let length, data.count - bodyStart >= length { break }
        }
        guard let head,
              let code = head.split(separator: " ").dropFirst().first.flatMap({ Int($0) }),
              (200..<300).contains(code) else { return nil }
        let body = data[bodyStart...]
        return chunked ? dechunk(body) : body
    }

    // "b12\r\n<2834 bytes>\r\n0\r\n\r\n" -> the bytes.
    static func dechunk(_ body: Data) -> Data {
        var out = Data()
        var i = body.startIndex
        let crlf = Data("\r\n".utf8)
        while i < body.endIndex, let line = body[i...].range(of: crlf) {
            let sizeText = String(decoding: body[i..<line.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard let size = Int(sizeText, radix: 16), size > 0 else { break }
            let start = line.upperBound
            let end = min(start + size, body.endIndex)
            out.append(body[start..<end])
            i = end + 2
        }
        return out
    }

    static func json(_ engine: Engine, _ path: String) -> Any? {
        request(engine, "GET", path).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    static func isUp(_ engine: Engine) -> Bool {
        request(engine, "GET", "/_ping", timeout: 1).map { String(decoding: $0, as: UTF8.self) } == "OK"
    }

    static func stop(_ e: Engine, _ name: String) { _ = request(e, "POST", "/containers/\(name)/stop", timeout: 30) }
    static func start(_ e: Engine, _ name: String) { _ = request(e, "POST", "/containers/\(name)/start", timeout: 30) }
    static func stop(_ c: Container) { stop(engine(of: c), c.name) }
    static func start(_ c: Container) { start(engine(of: c), c.name) }
    static func engine(of c: Container) -> Engine {
        Engine.known.first { $0.name == c.engine } ?? .docker
    }

    // "Up 9 hours (healthy)" -> "9 hr", "Up About an hour" -> "1 hr"
    static func shortUptime(_ status: String) -> String {
        var s = status.replacingOccurrences(of: "Up ", with: "")
            .replacingOccurrences(of: "About ", with: "")
        if let paren = s.firstIndex(of: "(") { s = String(s[..<paren]) }
        for (long, short) in [("an ", "1 "), ("a ", "1 "), (" minutes", " min"), (" minute", " min"),
                              (" hours", " hr"), (" hour", " hr"), (" seconds", " sec"),
                              ("Less than 1 second", "just now")] {
            s = s.replacingOccurrences(of: long, with: short)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

// Lists running containers with CPU and memory. Keeps the previous CPU counters
// because one-shot stats carry no "previous" sample of their own.
final class DockerScanner: @unchecked Sendable {
    let engine: Engine
    private var lastCPU: [String: (container: UInt64, system: UInt64)] = [:]

    init(_ engine: Engine) { self.engine = engine }

    func scan() -> [Container]? {
        // Running plus restarting: a crash loop is exactly what we want to catch.
        let filter = #"{"status":["running","restarting"]}"#
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        guard let list = Docker.json(engine, "/containers/json?filters=\(filter)") as? [[String: Any]]
        else { return nil }
        var next: [String: (UInt64, UInt64)] = [:]
        let containers: [Container] = list.compactMap { c in
            guard let name = (c["Names"] as? [String])?.first?.trimmingCharacters(in: ["/"])
            else { return nil }
            let labels = c["Labels"] as? [String: String] ?? [:]
            let port = (c["Ports"] as? [[String: Any]])?.compactMap { $0["PublicPort"] as? Int }.first
            var item = Container(
                engine: engine.name, name: name, image: c["Image"] as? String ?? "",
                project: labels["com.docker.compose.project"] ?? "", port: port,
                uptime: Docker.shortUptime(c["Status"] as? String ?? ""))
            item.restarting = (c["State"] as? String) == "restarting"

            if let st = Docker.json(engine, "/containers/\(name)/stats?stream=false&one-shot=true")
                as? [String: Any] {
                let mem = st["memory_stats"] as? [String: Any] ?? [:]
                let usage = (mem["usage"] as? NSNumber)?.doubleValue ?? 0
                let inactive = ((mem["stats"] as? [String: Any])?["inactive_file"] as? NSNumber)?
                    .doubleValue ?? 0
                item.mb = max(usage - inactive, 0) / 1_048_576

                let cs = st["cpu_stats"] as? [String: Any] ?? [:]
                let total = ((cs["cpu_usage"] as? [String: Any])?["total_usage"] as? NSNumber)?
                    .uint64Value ?? 0
                let system = (cs["system_cpu_usage"] as? NSNumber)?.uint64Value ?? 0
                let cpus = Double((cs["online_cpus"] as? NSNumber)?.intValue ?? 1)
                if let prev = lastCPU[name], system > prev.system, total >= prev.container {
                    item.cpu = Double(total - prev.container) / Double(system - prev.system) * cpus * 100
                }
                next[name] = (total, system)
            }
            return item
        }
        lastCPU = next
        return containers
    }
}

// MARK: - Model

// Only the menu bar icon watches this, so it redraws only when the verdict flips.
@MainActor
final class Status: ObservableObject {
    @Published var verdict = Verdict.smooth
    @Published var text = ""  // optional percentage next to the capsule
}

enum DockerState { case off, up, unresponsive }

// What's behind the verdict, so the header can name the app responsible.
enum Cause { case none, memory, cpu }

@MainActor
final class Model: ObservableObject {
    static let tick = 5.0  // seconds, system counters
    static let openTick = 2.0  // seconds, apps while the popover is open
    static let historyLength = 180  // 15 minutes of system ticks

    let status = Status()

    // Data refreshed on timers. Not @Published: refresh() sends one change
    // notification per update, and none at all while the popover is closed.
    private(set) var sample = Sample()
    private(set) var cpuHistory: [Double] = []  // percent busy
    private(set) var memHistory: [Double] = []  // GB used
    private(set) var swapHistory: [Double] = []  // GB
    private(set) var apps: [AppUsage] = []
    private(set) var engines: [Engine] = []  // container engines running right now
    private(set) var containers: [Container] = []  // running, across engines
    private(set) var scannedContainers = false  // at least once since the popover opened
    private(set) var reasons: [String] = []
    private(set) var cause = Cause.none
    private(set) var cpuSplit: (user: Double, system: Double) = (0, 0)  // percent of the whole Mac
    private(set) var disk: (free: Double, total: Double)?
    private var tickCount = 0
    private(set) var engineState: [String: DockerState] = [:]  // by Engine.name
    private var failures: [String: Int] = [:]  // container scans missed in a row, by Engine.name

    // State the user changes.
    @Published var stoppedHere: [Container] = []  // stopped from this popover, offered for Start
    @Published var busy: Set<String> = []  // container ids being stopped or started
    @Published var expanded: Set<String> = []  // projects shown open
    @Published var expandedApps: Set<String> = []  // apps showing their breakdown
    @Published var restartStatus: String?  // non-nil while restarting Docker
    @Published var confirmRestart = false

    private(set) var isOpen = false
    private var lastTicks: (user: UInt64, system: UInt64, idle: UInt64)?
    private var systemTimer: Timer?
    private var appTimer: Timer?
    private var openTicks = 0
    private let queue = DispatchQueue(label: "headroom.scan", qos: .utility)
    private let procs = ProcScanner()
    private let scanners = Engine.known.map(DockerScanner.init)

    init() {
        let args = CommandLine.arguments
        if args.contains("--dump") { dump() }
        if let i = args.firstIndex(of: "--screenshot"), i + 1 < args.count {
            DispatchQueue.main.async { self.screenshot(to: args[i + 1]) }
        }
        tickSystem()
        systemTimer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickSystem() }
        }
        systemTimer?.tolerance = 1  // let macOS batch our wakeups with others
    }

    // MARK: Open / close

    func opened() {
        guard !isOpen else { return }
        isOpen = true
        openTicks = 0
        scanApps()
        // A second scan soon after, so CPU percentages have a baseline to diff against.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.scanApps() }
        appTimer = Timer.scheduledTimer(withTimeInterval: Self.openTick, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scanApps() }
        }
        appTimer?.tolerance = 0.3
        objectWillChange.send()
    }

    // Popover closed: stop scanning and start fresh next time.
    func closed() {
        isOpen = false
        appTimer?.invalidate()
        appTimer = nil
        expanded = []
        expandedApps = []
        stoppedHere = []
        scannedContainers = false
        confirmRestart = false
    }

    // MARK: Sampling

    var cpuNow: Double { cpuHistory.last ?? 0 }

    // Swap change over the last two minutes, in GB.
    var swapTrend: Double {
        guard let last = swapHistory.last else { return 0 }
        let back = min(swapHistory.count - 1, Int(120 / Self.tick))
        return last - swapHistory[swapHistory.count - 1 - back]
    }

    var pressureLabel: String {
        switch sample.pressure {
        case 4: return "Critical"
        case 2: return "Elevated"
        default: return "Normal"
        }
    }

    private func tickSystem() {
        let s = sampleSystem()
        sample = s
        if let last = lastTicks {
            let user = Double(s.cpuTicks.user &- last.user), system = Double(s.cpuTicks.system &- last.system)
            let all = user + system + Double(s.cpuTicks.idle &- last.idle)
            if all > 0 {
                cpuSplit = (user / all * 100, system / all * 100)
                push(&cpuHistory, cpuSplit.user + cpuSplit.system)
            }
        }
        lastTicks = s.cpuTicks
        // Disk space barely moves, so once a minute is plenty.
        if tickCount % 12 == 0 { disk = sampleDisk() }
        tickCount += 1
        push(&memHistory, s.memUsed)
        push(&swapHistory, s.swapUsed)
        judge()
        refreshLabel()
        if isOpen { objectWillChange.send() }
    }

    func refreshLabel() {
        let mode = MenuText(rawValue: UserDefaults.standard.string(forKey: Pref.menuText) ?? "") ?? .none
        let text: String
        switch mode {
        case .none: text = ""
        // Labeled, so a bare percentage is never a guess.
        case .memory: text = String(format: "MEM %.0f%%", sample.memUsed / max(sample.total, 1) * 100)
        case .cpu: text = String(format: "CPU %.0f%%", cpuNow)
        }
        if status.text != text { status.text = text }
    }

    func scanApps() {
        guard isOpen else { return }
        let withContainers = openTicks % 2 == 0  // every 4 s
        openTicks += 1
        // An engine's app running is what matters, not its VM: when the VM dies
        // the app stays up and its socket stops answering.
        let running = Engine.known.filter { e in
            !NSRunningApplication.runningApplications(withBundleIdentifier: e.bundleID).isEmpty
        }
        let restarting = restartStatus != nil
        queue.async { [procs, scanners] in
            let apps = procs.scan()
            var scanned: [String: [Container]] = [:]  // engines whose socket answered
            if withContainers {
                for s in scanners where running.contains(s.engine) && (s.engine != .docker || !restarting) {
                    if let list = s.scan() { scanned[s.engine.name] = list }
                }
            }
            DispatchQueue.main.async {
                self.apps = apps
                self.engines = running
                for e in Engine.known where e != .docker || self.restartStatus == nil {  // leave Docker alone mid-restart
                    self.update(e, running: running.contains(e), scanned: scanned[e.name],
                                tried: withContainers)
                }
                if self.isOpen { self.objectWillChange.send() }
            }
        }
    }

    // One engine's containers after a scan. Two misses in a row (8 s) mean it
    // stopped answering; a single miss is just the engine still starting up.
    private func update(_ e: Engine, running: Bool, scanned: [Container]?, tried: Bool) {
        if !running {
            containers.removeAll { $0.engine == e.name }
            engineState[e.name] = .off
            failures[e.name] = 0
        } else if let list = scanned {
            containers.removeAll { $0.engine == e.name }
            containers += list
            scannedContainers = true
            stoppedHere.removeAll { c in list.contains { $0.id == c.id } }
            engineState[e.name] = .up
            failures[e.name] = 0
            rememberRunning(e, list)
        } else if tried {
            failures[e.name, default: 0] += 1
            if failures[e.name]! >= 2 {
                engineState[e.name] = .unresponsive
                containers.removeAll { $0.engine == e.name }
            }
        }
    }

    // MARK: Docker memory

    // The containers running at the last good scan, databases first. If Docker
    // breaks, these are what a restart brings back.
    func lastRunning(_ e: Engine) -> [String] {
        UserDefaults.standard.stringArray(forKey: e.lastContainersKey) ?? []
    }

    private func rememberRunning(_ e: Engine, _ list: [Container]) {
        let names = list.filter { !$0.restarting }.sorted { $0.isInfra && !$1.isInfra }.map(\.name)
        if names != lastRunning(e) { UserDefaults.standard.set(names, forKey: e.lastContainersKey) }
    }

    private func push(_ a: inout [Double], _ v: Double) {
        a.append(v)
        if a.count > Self.historyLength { a.removeFirst(a.count - Self.historyLength) }
    }

    // macOS's own pressure level is the best memory signal; growing swap means
    // it is paging right now; CPU counts only when it stays high for 30s.
    private func judge() {
        var v = Verdict.smooth
        var why: [String] = []
        var cause = Cause.none
        let recentCPU = cpuHistory.suffix(Int(30 / Self.tick))
        let cpu = recentCPU.isEmpty ? 0 : recentCPU.reduce(0, +) / Double(recentCPU.count)

        switch sample.pressure {
        case 4: v = .slow; why.append("Memory is critically low"); cause = .memory
        case 2: v = max(v, .busy); why.append("Memory is getting tight"); cause = .memory
        default: break
        }
        if swapTrend > 0.25 {
            v = .slow; why.append("Swapping to disk"); cause = .memory
        } else if swapTrend > 0.06 {
            v = max(v, .busy); why.append("Swap is growing"); cause = .memory
        }
        if cpu > 90 {
            v = .slow; why.append(String(format: "CPU maxed out (%.0f%%)", cpu))
            if cause == .none { cause = .cpu }
        } else if cpu > 70 {
            v = max(v, .busy); why.append(String(format: "CPU working hard (%.0f%%)", cpu))
            if cause == .none { cause = .cpu }
        }
        switch sample.thermal {
        case .critical:
            v = .slow; why.append("Mac is very hot, CPU heavily throttled")
            if cause == .none { cause = .cpu }
        case .serious:
            v = max(v, .busy); why.append("Mac is hot, CPU throttled")
            if cause == .none { cause = .cpu }
        default: break
        }
        if let disk {
            if disk.free < 5 {
                v = .slow; why.append(String(format: "Only %.0f GB free on disk", disk.free))
            } else if disk.free < 10 {
                v = max(v, .busy); why.append(String(format: "Disk almost full, %.0f GB free", disk.free))
            }
        }
        reasons = why
        self.cause = cause
        if status.verdict != v { status.verdict = v }
    }

    // MARK: Containers

    // Engines with a card: the running ones, plus Docker while it restarts.
    // Following Engine.known keeps the order stable while Docker quits and starts.
    var engineCards: [Engine] {
        Engine.known.filter { engines.contains($0) || ($0 == .docker && restartStatus != nil) }
    }

    // The app most responsible for the current verdict, e.g. "Chrome is using 6.1 GB".
    var culprit: String? {
        let candidates = apps.filter { !$0.isSystem && $0.name != "Headroom" }
        switch cause {
        case .none:
            return nil
        case .memory:
            guard let top = candidates.max(by: { $0.mb < $1.mb }), top.mb >= 500 else { return nil }
            if let e = engine(of: top), let c = containers(e).max(by: { ($0.mb ?? 0) < ($1.mb ?? 0) }),
               (c.mb ?? 0) > 0 {
                return "\(e.name) is using \(formatMB(top.mb)), most of it \(c.name)"
            }
            return "\(top.name) is using \(formatMB(top.mb))"
        case .cpu:
            // Per-core percentages pass 100 ("773%"); a share of the whole Mac reads better here.
            // Under 10% it isn't a culprit, e.g. when heat alone is the cause.
            let top = candidates.max(by: { $0.cpu < $1.cpu })
            // CPU we can't attribute to your apps belongs to macOS itself: Spotlight,
            // WindowServer, kernel_task. Those run as root, so we can't see them one by one.
            let system = cpuNow * coreCount - candidates.reduce(0) { $0 + $1.cpu }
            if system / coreCount >= 10 && system > (top?.cpu ?? 0) {
                return String(format: "macOS system processes are using %.0f%% of your CPU", cpuShare(system))
            }
            guard let top, cpuShare(top.cpu) >= 10 else { return nil }
            let share = cpuShare(top.cpu)
            if let e = engine(of: top), let c = containers(e).max(by: { ($0.cpu ?? 0) < ($1.cpu ?? 0) }),
               (c.cpu ?? 0) >= 5 {
                return String(format: "%@ (%@) is using %.0f%% of your CPU", e.name, c.name, share)
            }
            return String(format: "%@ is using %.0f%% of your CPU", top.name, share)
        }
    }

    func engine(of app: AppUsage) -> Engine? { Engine.known.first { $0.name == app.name } }

    func app(_ engine: Engine) -> AppUsage? { apps.first { $0.name == engine.name } }

    func state(_ engine: Engine) -> DockerState { engineState[engine.name] ?? .off }

    func containers(_ engine: Engine) -> [Container] { containers.filter { $0.engine == engine.name } }

    // Running and just-stopped containers of one engine, grouped by compose project.
    func projects(_ engine: Engine) -> [(name: String, items: [Container])] {
        Dictionary(grouping: (containers + stoppedHere).filter { $0.engine == engine.name }, by: \.project)
            .map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.name < $1.name }
    }

    func isStopped(_ c: Container) -> Bool { stoppedHere.contains { $0.id == c.id } }

    // Memory the VM holds beyond what its containers use, once stats are in.
    func vmSlackMB(_ engine: Engine) -> Double? {
        let cs = containers(engine)
        guard engine.canReclaim, let app = app(engine), !cs.isEmpty,
              cs.allSatisfy({ $0.mb != nil }) else { return nil }
        return app.vmMB - cs.reduce(0) { $0 + ($1.mb ?? 0) }
    }

    func toggle(_ project: String) {
        if expanded.contains(project) { expanded.remove(project) } else { expanded.insert(project) }
    }

    func toggle(_ app: AppUsage) {
        if expandedApps.contains(app.name) { expandedApps.remove(app.name) }
        else { expandedApps.insert(app.name) }
    }

    func stop(_ cs: [Container]) {
        guard !cs.isEmpty else { return }
        let ids = Set(cs.map(\.id))
        busy.formUnion(ids)
        DispatchQueue.global(qos: .userInitiated).async {
            DispatchQueue.concurrentPerform(iterations: cs.count) { Docker.stop(cs[$0]) }
            DispatchQueue.main.async {
                self.busy.subtract(ids)
                let gone = self.containers.filter { ids.contains($0.id) }
                self.containers.removeAll { ids.contains($0.id) }
                self.stoppedHere += gone
                self.scanApps()
            }
        }
    }

    func start(_ cs: [Container]) {
        guard !cs.isEmpty else { return }
        let ids = Set(cs.map(\.id))
        busy.formUnion(ids)
        DispatchQueue.global(qos: .userInitiated).async {
            cs.forEach(Docker.start)
            DispatchQueue.main.async {
                self.busy.subtract(ids)
                self.openTicks = 0  // make the next scan include containers
                self.scanApps()
            }
        }
    }

    // Quitting Docker Desktop hands the VM's memory back to macOS. Containers
    // without a restart policy stay down after that, so start them again ourselves.
    func restartDocker() {
        confirmRestart = false
        let engine = Engine.docker
        let current = containers(engine)
        let names = current.isEmpty ? lastRunning(engine)
                                    : current.sorted { $0.isInfra && !$1.isInfra }.map(\.name)
        restartStatus = "Quitting Docker…"
        engineState[engine.name] = .up
        failures[engine.name] = 0
        DispatchQueue.global(qos: .userInitiated).async {
            NSAppleScript(source: "quit app \"Docker\"")?.executeAndReturnError(nil)
            var waited = 0
            while Docker.isUp(engine) && waited < 60 { Thread.sleep(forTimeInterval: 1); waited += 1 }
            Thread.sleep(forTimeInterval: 5)  // let the backend exit before reopening

            DispatchQueue.main.async {
                self.restartStatus = "Starting Docker…"
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: engine.appPath),
                                                   configuration: .init())
            }
            waited = 0
            while !Docker.isUp(engine) && waited < 180 { Thread.sleep(forTimeInterval: 1); waited += 1 }

            if !names.isEmpty {
                DispatchQueue.main.async { self.restartStatus = "Starting \(names.count) containers…" }
                names.forEach { Docker.start(engine, $0) }
            }
            DispatchQueue.main.async {
                self.restartStatus = nil
                self.openTicks = 0
                self.scanApps()
            }
        }
    }

    // MARK: Apps

    // `Headroom.app/Contents/MacOS/Headroom --screenshot out.png [App …]`: shows
    // the popover's content in a window of its own, waits for the first scans,
    // expands the named apps, and saves the result. It is our own window, so no
    // screen recording permission is needed. For the README and for checking
    // layout changes without reaching for the mouse.
    private func screenshot(to path: String) {
        // A plain background stands in for the popover's blur, which only the
        // window server can draw.
        let effect = NSView()
        effect.wantsLayer = true
        effect.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let host = NSHostingView(rootView: ContentView(model: self))
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = effect
        window.center()
        window.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
            let args = CommandLine.arguments
            let names = args[(args.firstIndex(of: "--screenshot")! + 2)...]
            self.expandedApps = Set(names)
            self.expanded = Set(self.engines.flatMap { e in self.projects(e).map { e.name + "/" + $0.name } })
            self.objectWillChange.send()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let size = host.fittingSize
                window.setContentSize(size)
                host.frame = effect.bounds
                window.displayIfNeeded()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if let rep = effect.bitmapImageRepForCachingDisplay(in: effect.bounds) {
                        effect.cacheDisplay(in: effect.bounds, to: rep)
                        if let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: path))
                            print("saved \(path) (\(Int(size.width))×\(Int(size.height)) pt)")
                        }
                    }
                    exit(0)
                }
            }
        }
    }

    // `Headroom.app/Contents/MacOS/Headroom --dump`: prints every app and its
    // breakdown to the terminal, for checking how processes get grouped.
    private func dump() {
        for app in procs.scan().sorted(by: { $0.mb > $1.mb }) where app.mb >= 50 {
            print(String(format: "%@  %@  %d proc%@%@", formatMB(app.mb), app.name, app.count,
                         app.count == 1 ? "" : "s", app.isSystem ? "  (system)" : ""))
            for part in app.parts.sorted(by: { $0.mb > $1.mb }).prefix(8) {
                let pids = app.procs.filter { $0.label == part.label }.prefix(6).map { String($0.pid) }
                print(String(format: "    %@  %@%@%@  pid %@", formatMB(part.mb), part.label,
                             part.count > 1 ? " ×\(part.count)" : "",
                             part.detail.map { "  (\($0))" } ?? "", pids.joined(separator: ",")))
            }
        }
        exit(0)
    }

    func quit(_ app: AppUsage) {
        for r in running(app) { r.terminate() }
    }

    // Apple's apps run from a cryptex, so compare bundle names, not full paths:
    // /Applications/Safari.app is a link to /System/Volumes/Preboot/Cryptexes/…/Safari.app.
    func running(_ app: AppUsage) -> [NSRunningApplication] {
        guard let path = app.bundlePath else { return [] }
        let name = (path as NSString).lastPathComponent
        return NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL.map { $0.path == path || $0.lastPathComponent == name } ?? false
        }
    }
}

// MARK: - UI

// Colors tuned per appearance. System orange is too light to read as text on
// a light background, so text gets a deeper shade; fills keep the system hue.
extension Color {
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) {
            $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    // Translucent white tiles in light mode, a soft lift in dark mode.
    static let card = adaptive(light: .white.withAlphaComponent(0.62),
                               dark: .white.withAlphaComponent(0.07))
    static let cardEdge = adaptive(light: .black.withAlphaComponent(0.06),
                                   dark: .white.withAlphaComponent(0.08))
    static let track = adaptive(light: .black.withAlphaComponent(0.08),
                                dark: .white.withAlphaComponent(0.12))
    static let hover = adaptive(light: .black.withAlphaComponent(0.05),
                                dark: .white.withAlphaComponent(0.08))
    static let hoverStrong = adaptive(light: .black.withAlphaComponent(0.08),
                                      dark: .white.withAlphaComponent(0.14))
    static let warnText = adaptive(light: NSColor(srgbRed: 0.75, green: 0.32, blue: 0, alpha: 1),
                                   dark: .systemOrange)
}

enum SortKey: String, CaseIterable { case memory = "Memory", cpu = "CPU" }

// One button style for the whole popover. The system macOS styles don't react
// to the pointer, so every button here lights up on hover and dims on press.
// The fade is scoped to the button, so it never touches the window size.
enum HoverKind {
    case plain  // no background until hovered: footer icons
    case bordered  // soft fill: Quit…, Stop, Cancel
    case prominent(Color)  // solid: the confirming action
}

struct HoverButtonStyle: ButtonStyle {
    var kind: HoverKind = .bordered
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        HoverButton(configuration: configuration, kind: kind, small: small)
    }
}

private struct HoverButton: View {
    let configuration: ButtonStyle.Configuration
    let kind: HoverKind
    let small: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(small ? .caption.weight(.medium) : .subheadline)
            .foregroundStyle(foreground)
            .padding(.horizontal, small ? 7 : 8)
            .padding(.vertical, small ? 2 : 3)
            .background(RoundedRectangle(cornerRadius: small ? 5 : 6, style: .continuous)
                .fill(fill(pressed: pressed)))
            .brightness(pressedBrightness(pressed))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 && isEnabled }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.08), value: pressed)
    }

    var foreground: Color {
        switch kind {
        case .plain: return hovering ? .primary : .secondary
        case .bordered: return .primary
        case .prominent: return .white
        }
    }

    func fill(pressed: Bool) -> Color {
        switch kind {
        case .plain: return pressed ? .hoverStrong.opacity(1.4) : hovering ? .hoverStrong : .clear
        case .bordered: return Color.primary.opacity(pressed ? 0.2 : hovering ? 0.15 : 0.09)
        case .prominent(let c): return c
        }
    }

    // Solid buttons brighten on hover and darken on press, like the system ones.
    func pressedBrightness(_ pressed: Bool) -> Double {
        guard case .prominent = kind else { return 0 }
        return pressed ? -0.12 : hovering ? 0.08 : 0
    }
}

extension ButtonStyle where Self == HoverButtonStyle {
    static var hoverPlain: HoverButtonStyle { HoverButtonStyle(kind: .plain) }
    static var hoverBordered: HoverButtonStyle { HoverButtonStyle(kind: .bordered) }
    static var hoverSmall: HoverButtonStyle { HoverButtonStyle(kind: .bordered, small: true) }
    static func hoverProminent(_ c: Color, small: Bool = false) -> HoverButtonStyle {
        HoverButtonStyle(kind: .prominent(c), small: small)
    }
}

// Menus can't take a ButtonStyle, so the sort menu gets the same hover by hand.
struct HoverMenuBackground: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? Color.hover : .clear))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// App icons are cached: NSWorkspace builds a fresh image on every call.
@MainActor
enum Icons {
    private static var cache: [String: NSImage] = [:]

    static func app(_ path: String) -> NSImage? {
        if let img = cache[path] { return img }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        // Draw once at display size; the source icon is up to 1024 px and
        // scaling it down on every redraw shows up in profiles.
        let src = NSWorkspace.shared.icon(forFile: path)
        let size = NSSize(width: 36, height: 36)  // 18 pt at 2x
        let img = NSImage(size: NSSize(width: 18, height: 18))
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            src.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            rep.size = NSSize(width: 18, height: 18)
            img.addRepresentation(rep)
        }
        cache[path] = img
        return img
    }
}

// The grouped-card look of Control Center.
struct Card<Content: View>: View {
    var tint: Color? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                shape.fill(Color.card)
                if let tint { shape.fill(tint.opacity(0.12)) }
                shape.strokeBorder(Color.cardEdge, lineWidth: 0.5)
            }
    }
}

struct ContentView: View {
    @ObservedObject var model: Model
    @State private var sort = SortKey.memory
    @State private var confirmQuit = false
    @State private var showSettings = false
    @AppStorage(Pref.appCount) private var appCount = 5
    @AppStorage(Pref.showDocker) private var showDocker = true
    @AppStorage("showAllApps") private var showAll = false  // "More…" stays on until "Less"

    var body: some View {
        VStack(spacing: 8) {
            if showSettings {
                SettingsView(model: model) { showSettings = false }
            } else {
                header
                HStack(spacing: 8) { tiles }
                appsCard
                if showDocker {
                    ForEach(model.engineCards) { EngineCard(engine: $0, model: model) }
                }
                footer
            }
        }
        .padding(10)
        .frame(width: 340)
        .onAppear {
            model.opened()
            // Open on the list that shows the culprit.
            sort = model.cause == .cpu ? .cpu : .memory
        }
        .onDisappear {
            model.closed()
            confirmQuit = false
            showSettings = false
        }
    }

    // MARK: Header

    var header: some View {
        let v = model.status.verdict
        return Card(tint: v.color) {
            HStack(spacing: 10) {
                Image(systemName: v.symbol)
                    .font(.system(size: 26))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, v.color)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.snappy, value: v)
                VStack(alignment: .leading, spacing: 1) {
                    Text(v.title).font(.headline)
                    // One line per reason: several can be true at once.
                    ForEach(model.reasons.isEmpty ? ["Plenty of memory and CPU to spare"] : model.reasons,
                            id: \.self) { reason in
                        Text(reason)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let culprit = model.culprit {
                        Text(culprit)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: Tiles

    @ViewBuilder var tiles: some View {
        let s = model.sample
        let swapWord = model.swapTrend > 0.06 ? "growing"
                     : model.swapTrend < -0.06 ? "shrinking" : "steady"
        let memColor: Color = s.pressure >= 4 ? .red : s.pressure >= 2 ? .orange : .green
        Tile(label: "Memory", value: String(format: "%.1f GB", s.memUsed),
             detail: model.pressureLabel,
             detailColor: s.pressure >= 4 ? .red : s.pressure >= 2 ? .warnText : .secondary,
             history: model.memHistory, maxY: s.total, color: memColor,
             parts: [(s.appMem, memColor), (s.wired, .blue), (s.compressed, .purple)], partsTotal: s.total,
             partsHelp: String(format: "App %.1f GB · Wired %.1f GB · Compressed %.1f GB · Free and cache %.1f GB",
                               s.appMem, s.wired, s.compressed, max(s.total - s.memUsed, 0)))
            .help(String(format: "%.1f of %.0f GB in use. Pressure: %@", s.memUsed, s.total,
                         model.pressureLabel.lowercased()))

        // Heat replaces the core count when macOS is throttling the CPU.
        let heat: (String, Color)? = switch s.thermal {
        case .fair: ("Warm", .secondary)
        case .serious: ("Hot, throttled", .warnText)
        case .critical: ("Very hot, throttled", .red)
        default: nil
        }
        Tile(label: "CPU", value: String(format: "%.0f%%", model.cpuNow),
             detail: heat?.0 ?? "\(ProcessInfo.processInfo.activeProcessorCount) cores",
             detailColor: heat?.1 ?? .secondary,
             history: model.cpuHistory, maxY: 100,
             color: model.cpuNow > 90 ? .red : model.cpuNow > 70 ? .orange : .blue,
             parts: [(model.cpuSplit.user, .blue), (model.cpuSplit.system, .red)], partsTotal: 100,
             partsHelp: String(format: "User %.0f%% · System %.0f%% · Idle %.0f%%", model.cpuSplit.user,
                               model.cpuSplit.system, max(100 - model.cpuNow, 0)))

        // Swap lives on the startup disk, so this tile also watches disk space.
        let disk = model.disk
        let diskLow = (disk?.free ?? .infinity) < 10
        let diskColor: Color = (disk?.free ?? .infinity) < 5 ? .red : diskLow ? .orange : .gray
        Tile(label: "Swap", value: String(format: "%.1f GB", s.swapUsed),
             detail: diskLow ? String(format: "%.0f GB disk free", disk!.free) : swapWord,
             detailColor: diskLow ? .warnText : swapWord == "growing" ? .warnText : .secondary,
             history: model.swapHistory, maxY: max(1, (model.swapHistory.max() ?? 0) * 1.2),
             color: swapWord == "growing" ? .orange : .gray,
             parts: disk.map { [($0.total - $0.free, diskColor)] } ?? [], partsTotal: disk?.total ?? 1,
             partsHelp: disk.map { String(format: "Startup disk: %.0f GB free of %.0f GB", $0.free, $0.total) } ?? "")
    }

    // MARK: Apps

    var appsCard: some View {
        // Container engines get their own card below, with the same total.
        let engines: Set<String> = showDocker ? Set(model.engineCards.map(\.name)) : []
        let all = model.apps.filter { !engines.contains($0.name) && $0.name != "Headroom" }
        let key: (AppUsage) -> Double = { sort == .memory ? $0.mb : $0.cpu }
        let sorted = all.sorted { key($0) > key($1) }
        // "More" lists everything that amounts to anything, in a scrolling list.
        let rows = showAll ? sorted.filter { $0.mb >= 10 || $0.cpu >= 1 } : Array(sorted.prefix(appCount))
        let top = max(rows.first.map(key) ?? 1, 1)

        return Card {
            VStack(spacing: 2) {
                HStack {
                    // Only when the Mac actually is slow: a big app on a healthy Mac isn't slowing you down.
                    Text(model.status.verdict != .smooth && rows.contains { isHot($0) } ? "Slowing you down"
                         : showAll ? "All apps" : "Top apps")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Picker("Sort by", selection: $sort) {
                            ForEach(SortKey.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text(sort.rawValue)
                    }
                    .menuStyle(.borderlessButton)
                    .font(.subheadline)
                    .fixedSize()
                    .modifier(HoverMenuBackground())
                }
                .padding(.bottom, 2)

                if rows.isEmpty {
                    ProgressView().controlSize(.small).frame(height: 26 * CGFloat(appCount))
                }
                let list = ForEach(rows) { app in
                    AppRow(app: app, sort: sort, share: key(app) / top, hot: isHot(app),
                           model: model)
                    if model.expandedApps.contains(app.name) {
                        Breakdown(app: app, sort: sort)
                    }
                }
                // Rows have fixed heights, so the list's height is arithmetic:
                // as tall as its content, up to about 14 rows, then it scrolls (in both modes).
                do {
                    let height = rows.reduce(CGFloat(0)) { h, app in
                        let open = model.expandedApps.contains(app.name)
                        let parts = open ? min(app.parts.count, Breakdown.maxRows + 1) : 0
                        return h + 26 + 2 + CGFloat(parts) * (24 + 2)
                    }
                    ScrollView(.vertical, showsIndicators: false) { VStack(spacing: 2) { list } }
                        .frame(height: min(height, 26 * 14))
                }

                Button(showAll ? "Less" : "More…") { showAll.toggle() }
                    .buttonStyle(.hoverSmall)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 4)
                    .help(showAll ? "Back to the top \(appCount)" : "Every app, with a breakdown for each")
            }
        }
    }

    func isHot(_ app: AppUsage) -> Bool {
        !app.isSystem && (sort == .memory ? app.mb >= 2048 : cpuShare(app.cpu) >= 25)
    }

    // MARK: Footer

    // Asks before quitting, in place, so the popover keeps its size.
    var footer: some View {
        HStack {
            if confirmQuit {
                Text("Quit Headroom?").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { confirmQuit = false }
                    .buttonStyle(.hoverBordered)
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.hoverProminent(.red))
                    .keyboardShortcut(.defaultAction)
            } else {
                Button {
                    NSWorkspace.shared.open(
                        URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                } label: {
                    Label("Activity Monitor", systemImage: "waveform.path.ecg")
                }
                .buttonStyle(.hoverPlain)
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.hoverPlain)
                .help("Settings")
                Button {
                    confirmQuit = true
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.hoverPlain)
                .help("Quit Headroom")
            }
        }
        .font(.subheadline)
        .frame(height: 24)
        .padding(.top, 2)
    }
}

struct Tile: View {
    let label: String
    let value: String
    let detail: String
    let detailColor: Color
    let history: [Double]
    let maxY: Double
    let color: Color
    var parts: [(Double, Color)] = []  // what the value is made of, drawn as a thin bar
    var partsTotal: Double = 1
    var partsHelp = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(detail).font(.caption2).foregroundStyle(detailColor).lineLimit(1)
            PartsBar(parts: parts, total: partsTotal)
                .padding(.top, 5)
                .help(partsHelp)
            Sparkline(values: history, maxY: maxY, color: color)
                .frame(height: 20)
                .padding(.top, 4)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            shape.fill(Color.card)
            shape.strokeBorder(Color.cardEdge, lineWidth: 0.5)
        }
    }
}

// A thin stacked bar: each part's share of the total, the rest left as track.
struct PartsBar: View {
    let parts: [(Double, Color)]
    let total: Double

    var body: some View {
        GeometryReader { g in
            HStack(spacing: 1) {
                ForEach(parts.indices, id: \.self) { i in
                    let share = max(parts[i].0, 0) / max(total, 0.001)
                    if share > 0.005 {
                        Rectangle().fill(parts[i].1).frame(width: g.size.width * min(share, 1))
                    }
                }
                Spacer(minLength: 0)
            }
            .background(Color.track)
            .clipShape(Capsule())
        }
        .frame(height: 4)
    }
}

// No animations on values that refresh every few seconds: each one keeps the
// display link redrawing the window at 120 Hz, which tripled our CPU and grew
// memory. Only user actions animate (the chevron, the verdict symbol).

// A plain Path instead of Swift Charts: one shape, no layout engine.
struct Sparkline: View {
    let values: [Double]
    let maxY: Double
    let color: Color

    var body: some View {
        ZStack {
            SparkShape(values: values, maxY: maxY, closed: true)
                .fill(LinearGradient(colors: [color.opacity(0.3), color.opacity(0)],
                                     startPoint: .top, endPoint: .bottom))
            SparkShape(values: values, maxY: maxY, closed: false)
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

struct SparkShape: Shape {
    let values: [Double]
    let maxY: Double
    let closed: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard values.count > 1, maxY > 0 else { return p }
        let step = rect.width / CGFloat(values.count - 1)
        let point = { (i: Int) -> CGPoint in
            let v = min(max(values[i] / maxY, 0), 1)
            return CGPoint(x: CGFloat(i) * step, y: rect.maxY - CGFloat(v) * (rect.height - 1.5))
        }
        p.move(to: point(0))
        for i in 1..<values.count { p.addLine(to: point(i)) }
        if closed {
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
        }
        return p
    }
}

// Thin capsule showing a row's share of the biggest row.
struct ShareBar: View {
    let share: Double
    let color: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.track)
                Capsule().fill(color)
                    .frame(width: max(4, g.size.width * min(max(share, 0), 1)))
            }
        }
        .frame(width: 56, height: 5)
    }
}

struct AppRow: View {
    let app: AppUsage
    let sort: SortKey
    let share: Double
    let hot: Bool
    @ObservedObject var model: Model
    @State private var hovering = false
    @State private var confirming = false

    var body: some View {
        let open = model.expandedApps.contains(app.name)
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(open ? 90 : 0))
                .animation(.snappy(duration: 0.15), value: open)
                .opacity(app.hasBreakdown ? 1 : 0)
                .frame(width: 8)
            icon.frame(width: 18, height: 18)
            if confirming {
                // Same row, same height: the confirm swaps in without resizing the popover.
                Text("Quit \(app.name)?").lineLimit(1)
                Spacer(minLength: 6)
                Button("Cancel") { confirming = false }
                    .buttonStyle(.hoverSmall)
                Button("Quit") {
                    confirming = false
                    model.quit(app)
                }
                .buttonStyle(.hoverProminent(.red, small: true))
            } else {
                Text(app.name).lineLimit(1)
                Spacer(minLength: 6)
                if hovering && canQuit {
                    Button("Quit…") { confirming = true }
                        .buttonStyle(.hoverSmall)
                } else {
                    ShareBar(share: share, color: hot ? .orange : .accentColor)
                }
                Text(sort == .memory ? formatMB(app.mb) : String(format: "%.0f%%", cpuShare(app.cpu)))
                    .monospacedDigit()
                    .fontWeight(hot ? .semibold : .regular)
                    .foregroundStyle(hot ? Color.warnText : Color.primary)
                    .frame(width: 58, alignment: .trailing)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(hovering ? Color.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if app.hasBreakdown && !confirming { model.toggle(app) } }
        .onDisappear { confirming = false }
        .help(tooltip)
    }

    var tooltip: String {
        var parts = [formatMB(app.mb), String(format: "%.0f%% CPU", cpuShare(app.cpu))]
        if app.count > 1 { parts.append("\(app.count) processes") }
        if app.hasBreakdown { parts.append("click for a breakdown") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder var icon: some View {
        if let path = app.bundlePath, let img = Icons.app(path) {
            Image(nsImage: img).resizable()
        } else {
            // Command-line things get a terminal; macOS internals a gear.
            Image(systemName: app.isSystem ? "gearshape.fill" : "terminal.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
        }
    }

    var canQuit: Bool {
        !app.isSystem && !model.running(app).isEmpty
    }
}

// MARK: App breakdown

// What an app's memory is made of: the scripts a Python runs, a browser's
// tabs and extensions, an IDE next to its helpers. Biggest rows first; the
// long tail folds into one line so the popover stays short.
struct Breakdown: View {
    let app: AppUsage
    let sort: SortKey
    static let maxRows = 6

    var body: some View {
        let key: (AppPart) -> Double = { sort == .memory ? $0.mb : $0.cpu }
        let parts = app.parts.sorted { key($0) > key($1) }
        let shown = parts.prefix(Self.maxRows)
        let rest = parts.dropFirst(Self.maxRows)
        ForEach(shown) { PartRow(part: $0, sort: sort) }
        if !rest.isEmpty {
            PartRow(part: AppPart(label: "\(rest.count) more", detail: nil,
                                  mb: rest.reduce(0) { $0 + $1.mb }, cpu: rest.reduce(0) { $0 + $1.cpu },
                                  count: rest.reduce(0) { $0 + $1.count }),
                    sort: sort, isTail: true)
        }
    }
}

struct PartRow: View {
    let part: AppPart
    let sort: SortKey
    var isTail = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(part.label)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isTail ? .secondary : .primary)
                .layoutPriority(1)
            if part.count > 1 && !isTail {
                Text("×\(part.count)").foregroundStyle(.secondary).monospacedDigit().fixedSize()
            }
            Spacer(minLength: 6)
            if let folder = shortFolder {
                // Drop the folder when there is no room, rather than showing a lone "…".
                ViewThatFits(in: .horizontal) {
                    Text(folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    Color.clear.frame(width: 0)
                }
            }
            Text(sort == .memory ? formatMB(part.mb) : String(format: "%.0f%%", cpuShare(part.cpu)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
        }
        .font(.callout)
        .padding(.leading, 40)
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(hovering ? Color.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(tooltip)
    }

    // The row has room for a folder name, not a path: "~/Code/AI/workflows/src/jev"
    // -> "workflows/src/jev". The full path is in the tooltip. Other details
    // ("largest 1.4 GB") stay in the tooltip too.
    var shortFolder: String? {
        guard let d = part.detail, d.hasPrefix("~") || d.hasPrefix("/") else { return nil }
        let parts = d.split(separator: "/").map(String.init)
        let noise = ["src", "dist", "lib", "bin", "build", "out", "scripts"]
        guard let last = parts.last else { return nil }
        if noise.contains(last), parts.count >= 2 {
            return parts.suffix(3).joined(separator: "/")
        }
        // CLI tools are already labelled by their folder; don't say it twice.
        return last == part.label ? nil : last
    }

    // "serve.py · ~/Documents/Code/AI/workflows · 248 MB · 3% CPU"
    var tooltip: String {
        var parts = [part.label]
        if let detail = part.detail { parts.append(detail) }
        if part.count > 1 { parts.append("\(part.count) processes") }
        parts += [formatMB(part.mb), String(format: "%.0f%% CPU", cpuShare(part.cpu))]
        return parts.joined(separator: " · ")
    }
}

// MARK: Container engine card

// Expanding and collapsing is deliberately not animated: the popover window
// resizes to fit, and animating that resize makes the whole window flicker.
struct EngineCard: View {
    let engine: Engine
    @ObservedObject var model: Model

    var body: some View {
        let app = model.app(engine)
        let projects = model.projects(engine)
        let restarting = engine == .docker ? model.restartStatus : nil
        Card {
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    if let img = Icons.app(engine.appPath) {
                        Image(nsImage: img).resizable().frame(width: 16, height: 16)
                    }
                    Text(engine.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let app {
                        Text(String(format: "%@ · %.0f%% CPU", formatMB(app.mb), cpuShare(app.cpu)))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .help(String(format: "%@ as a whole. Its Linux VM, which runs every container, holds %@.",
                                         engine.name, formatMB(app.vmMB)))
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 2)

                if let status = restarting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(status).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 28)
                } else if model.state(engine) == .unresponsive {
                    DockerDownNote(engine: engine, model: model)
                } else {
                    CrashNote(engine: engine, model: model)
                    ForEach(projects, id: \.name) { project in
                        ProjectRow(name: project.name, items: project.items, model: model)
                        if model.expanded.contains(engine.name + "/" + project.name) {
                            ForEach(project.items) { ContainerRow(c: $0, model: model) }
                        }
                    }
                    if projects.isEmpty {
                        Text(app == nil ? "\(engine.name) isn't running"
                             : model.containers.isEmpty && model.stoppedHere.isEmpty && !loaded
                             ? "Loading containers…" : "No containers running")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .frame(height: 26)
                    }
                    SlackNote(engine: engine, model: model)
                }
            }
        }
    }

    // The first container scan lands a few seconds after the popover opens.
    var loaded: Bool { model.scannedContainers }
}

struct ProjectRow: View {
    let name: String
    let items: [Container]
    @ObservedObject var model: Model
    @State private var hovering = false

    // Projects of different engines may share a name; the toggle key doesn't.
    var key: String { (items.first?.engine ?? "") + "/" + name }

    var body: some View {
        let running = items.filter { !model.isStopped($0) }
        let mb = running.reduce(0) { $0 + ($1.mb ?? 0) }
        let anyBusy = items.contains { model.busy.contains($0.id) }
        let open = model.expanded.contains(key)

        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(open ? 90 : 0))
                .animation(.snappy(duration: 0.15), value: open)
                .frame(width: 18)
            Text(name.isEmpty ? "Other" : name).lineLimit(1)
            HStack(spacing: 3) {
                ForEach(items) { c in
                    Circle()
                        .fill(c.restarting ? Color.red
                              : model.isStopped(c) ? Color.secondary.opacity(0.35) : Color.green)
                        .frame(width: 5, height: 5)
                }
            }
            .help("\(running.count) of \(items.count) running")
            Spacer(minLength: 6)
            if anyBusy {
                ProgressView().controlSize(.mini)
            } else if hovering {
                if running.isEmpty {
                    Button("Start") { model.start(items) }
                        .buttonStyle(.hoverSmall)
                } else {
                    Button(running.count == 1 ? "Stop" : "Stop All") { model.stop(running) }
                        .buttonStyle(.hoverSmall)
                }
            }
            Text(running.isEmpty ? "Stopped" : mb > 0 ? formatMB(mb) : "")
                .monospacedDigit()
                .foregroundStyle(running.isEmpty ? .secondary : .primary)
                .frame(width: 58, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(hovering ? Color.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.toggle(key) }
    }
}

struct ContainerRow: View {
    let c: Container
    @ObservedObject var model: Model
    @State private var hovering = false

    var body: some View {
        let stopped = model.isStopped(c)
        let busy = model.busy.contains(c.id)

        HStack(spacing: 8) {
            Circle()
                .fill(c.restarting ? Color.red : stopped ? Color.secondary.opacity(0.35) : Color.green)
                .frame(width: 6, height: 6)
                .frame(width: 18)
            Text(c.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            if busy {
                Text(stopped ? "Starting…" : "Stopping…").foregroundStyle(.secondary)
                ProgressView().controlSize(.mini)
            } else {
                if c.restarting {
                    if !hovering { Text("Crashing").foregroundStyle(Color.warnText) }
                } else {
                    // CPU steps aside on hover to make room for Stop; the port stays,
                    // since hovering the row is the only way to reach it.
                    if let cpu = c.cpu, cpuShare(cpu) >= 5, !stopped, !hovering {
                        Text(String(format: "%.0f%%", cpuShare(cpu)))
                            .foregroundStyle(Color.warnText)
                            .monospacedDigit()
                            .help("Share of your Mac's CPU")
                    }
                    if let port = c.port, !stopped {
                        // A plain String: SwiftUI formats numbers inside text literals for the
                        // locale, which turned port 8003 into "8,003".
                        let label = ":" + String(port)
                        if c.isInfra {
                            Text(verbatim: label).foregroundStyle(.secondary).monospacedDigit()
                        } else {
                            // Web containers open in the browser; databases have nothing to show.
                            Button {
                                NSWorkspace.shared.open(URL(string: "http://localhost" + label)!)
                            } label: {
                                Text(verbatim: label)
                            }
                            .buttonStyle(.hoverSmall)
                            .help(Text(verbatim: "Open localhost" + label))
                        }
                    }
                }
                if hovering {
                    Button(stopped ? "Start" : "Stop") {
                        stopped ? model.start([c]) : model.stop([c])
                    }
                    .buttonStyle(.hoverSmall)
                }
            }
            Text(stopped ? "Stopped" : c.mb.map(formatMB) ?? "")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
        }
        .font(.callout)
        .opacity(stopped && !hovering ? 0.6 : 1)
        .padding(.leading, 14)
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(hovering ? Color.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(tooltip)
    }

    // "web · up 9 hr · 7% CPU"
    var tooltip: String {
        var parts = [c.shortImage, "up " + c.uptime]
        if let cpu = c.cpu { parts.append(String(format: "%.0f%% CPU", cpuShare(cpu))) }
        return parts.joined(separator: " · ")
    }
}

// A container stuck restarting burns CPU and can kick off other work on every
// start (on Sep 24 one re-ran a chown that made Spotlight re-index 217 PDFs a minute).
struct CrashNote: View {
    let engine: Engine
    @ObservedObject var model: Model

    var body: some View {
        let crashing = model.containers(engine).filter(\.restarting)
        if !crashing.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Color.warnText)
                Text(crashing.count == 1 ? "\(crashing[0].name) keeps crashing"
                     : "\(crashing.count) containers keep crashing")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(crashing.count == 1 ? "Stop" : "Stop All") { model.stop(crashing) }
                    .buttonStyle(.hoverSmall)
            }
            .font(.callout)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.12)))
            .padding(.bottom, 4)
            .help("\(engine.name) keeps restarting \(crashing.count == 1 ? "this container" : "these containers") because \(crashing.count == 1 ? "it exits" : "they exit") on start. Stopping ends the loop until you start \(crashing.count == 1 ? "it" : "them") again.")
        }
    }
}

// The engine's app is running but its socket stopped answering, usually because
// the VM died. For Docker, restarting brings it back, along with whatever was
// running. OrbStack recovers on its own or wants a quit and reopen by hand.
struct DockerDownNote: View {
    let engine: Engine
    @ObservedObject var model: Model

    var body: some View {
        let count = model.lastRunning(engine).count
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.warnText)
                Text("\(engine.name) isn't responding").fontWeight(.medium)
            }
            Text(engine != .docker ? "Quitting and reopening \(engine.name) usually fixes this."
                 : count == 0 ? "Restarting Docker usually fixes this."
                 : "\(count) container\(count == 1 ? " was" : "s were") running. Restarting Docker brings \(count == 1 ? "it" : "them") back.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if engine == .docker {
                HStack {
                    Spacer()
                    Button("Restart Docker") { model.restartDocker() }
                        .buttonStyle(.hoverProminent(.accentColor))
                }
            }
        }
        .font(.callout)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.orange.opacity(0.12)))
    }
}

// The VM grows to fit what containers once used and keeps it; only a Docker
// restart gives it back. One line until clicked, then an inline confirm.
struct SlackNote: View {
    let engine: Engine
    @ObservedObject var model: Model

    var body: some View {
        if let slack = model.vmSlackMB(engine), slack >= 2048 {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "memorychip").foregroundStyle(Color.warnText)
                    Text("\(formatMB(slack)) idle in the VM")
                    Spacer()
                    if !model.confirmRestart {
                        Button("Reclaim…") { model.confirmRestart = true }
                            .buttonStyle(.hoverSmall)
                    }
                }
                .help("Docker's VM keeps memory its containers no longer use. Restarting Docker gives it back to macOS.")
                if model.confirmRestart {
                    Text("Docker will quit and reopen, then start your \(model.containers(engine).count) running containers again. Takes about a minute.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Cancel") { model.confirmRestart = false }
                            .buttonStyle(.hoverBordered)
                        Button("Restart Docker") { model.restartDocker() }
                            .buttonStyle(.hoverProminent(.accentColor))
                    }
                }
            }
            .font(.callout)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.12)))
            .padding(.top, 4)
        }
    }
}

// MARK: - Settings view

// Settings live inside the popover rather than in a separate window: windows
// opened from a menu bar app tend to appear behind whatever is in front.
struct SettingsView: View {
    @ObservedObject var model: Model
    let done: () -> Void
    @AppStorage(Pref.menuText) private var menuText = MenuText.none.rawValue
    @AppStorage(Pref.appCount) private var appCount = 5
    @AppStorage(Pref.showDocker) private var showDocker = true
    @State private var loginStatus = LoginItem.status
    @State private var loginError: String?

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Settings").font(.headline)
                Spacer()
                Button("Done", action: done)
                    .buttonStyle(.hoverBordered)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 6)
            .frame(height: 28)

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SettingRow("Open at login") {
                        Toggle("Open at login", isOn: Binding(
                            get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                            set: { on in
                                do { try LoginItem.set(on); loginError = nil } catch {
                                    loginError = error.localizedDescription
                                }
                                loginStatus = LoginItem.status
                            }))
                    }
                    if loginStatus == .requiresApproval {
                        HStack {
                            Text("macOS needs your OK in Login Items.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                                .buttonStyle(.hoverSmall)
                        }
                    }
                    if let loginError {
                        Text(loginError).font(.caption).foregroundStyle(Color.warnText)
                    }
                    Divider()
                    SettingRow("Menu bar shows") {
                        Picker("Menu bar shows", selection: $menuText) {
                            ForEach(MenuText.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SettingRow("Apps to list") {
                        Picker("Apps to list", selection: $appCount) {
                            ForEach([5, 7, 10], id: \.self) { Text("\($0)").tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                    Divider()
                    SettingRow("Show containers") { Toggle("Show containers", isOn: $showDocker) }
                }
            }

            Card {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Headroom \(version)").fontWeight(.medium)
                        Text("Free and open source, MIT license").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("GitHub") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/julioest/headroom")!)
                    }
                    .buttonStyle(.hoverBordered)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .onChange(of: menuText) { model.refreshLabel() }
        .onAppear { loginStatus = LoginItem.status }
    }

    var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}

// Label on the left, control on the right, like System Settings.
struct SettingRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: () -> Control

    init(_ title: String, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.control = control
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            control().labelsHidden()
        }
        .frame(minHeight: 22)
    }
}

// MARK: - Menu bar

// A capsule that fills as the Mac gets busy: the empty space at the top is the
// headroom. Smooth stays a plain template image so it blends in like system
// icons; busy and slow are drawn in orange and red. Built once per verdict.
@MainActor
enum MenuIcon {
    private static var cache: [Verdict: NSImage] = [:]

    static func image(_ v: Verdict) -> NSImage {
        if let img = cache[v] { return img }
        let color = v == .smooth ? NSColor.black : v.nsColor
        // Flipped so the coordinates read top-down, like the design sketches.
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            color.set()
            let capsule = NSBezierPath(roundedRect: NSRect(x: 4.75, y: 1.75, width: 8.5, height: 14.5),
                                       xRadius: 4.25, yRadius: 4.25)
            capsule.lineWidth = 1.5
            capsule.stroke()
            let r = min(2.4, v.level / 2)  // a short fill stays a pill, not a blob
            NSBezierPath(roundedRect: NSRect(x: 6.6, y: 14.65 - v.level, width: 4.8, height: v.level),
                         xRadius: r, yRadius: r).fill()
            return true
        }
        img.isTemplate = v == .smooth
        img.accessibilityDescription = v.title
        cache[v] = img
        return img
    }
}

struct MenuLabel: View {
    @ObservedObject var status: Status

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: MenuIcon.image(status.verdict))
            if !status.text.isEmpty {
                Text(status.text).monospacedDigit()
            }
        }
    }
}

@main
struct HeadroomApp: App {
    // @State, not @StateObject: the scene itself shouldn't re-render when the
    // model changes. Only the label (via Status) and the open popover observe.
    @State private var model = Model()

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: model)
        } label: {
            MenuLabel(status: model.status)
        }
        .menuBarExtraStyle(.window)
    }
}

import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Keeps a bounded reservoir of frames-per-second samples, at most one taken
/// per second, and summarises them. Pure and thread safe; the display link
/// only feeds it.
final class RavensightHealthSampler {
    static let maxSamples = 600
    private let lock = NSLock()
    private var samples: [Double] = []
    private var next = 0
    private var lastSampleAt: TimeInterval?

    /// Called from the frame hook with the last frame's duration. Takes a
    /// sample only when a second has passed since the previous one.
    func offer(frameSeconds: TimeInterval, at now: TimeInterval) {
        guard frameSeconds > 0, frameSeconds.isFinite else { return }
        lock.lock()
        defer { lock.unlock() }
        if let last = lastSampleAt, now - last < 1 { return }
        lastSampleAt = now
        add(1 / frameSeconds)
    }

    private func add(_ fps: Double) {
        if samples.count < RavensightHealthSampler.maxSamples {
            samples.append(fps)
        } else {
            samples[next] = fps
            next = (next + 1) % RavensightHealthSampler.maxSamples
        }
    }

    var sampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }

    /// Median and 10th percentile (nearest rank) of fps, nil with no samples.
    func summary() -> (median: Double, p10: Double)? {
        lock.lock()
        let sorted = samples.sorted()
        lock.unlock()
        guard !sorted.isEmpty else { return nil }
        let n = sorted.count
        let median = n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
        let rank = Int((0.1 * Double(n)).rounded(.up))
        return (median, sorted[max(rank, 1) - 1])
    }

    /// Resident footprint in MB via task_vm_info, nil if unavailable.
    static func memoryMb() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
    }

    /// Milliseconds from this process's start to now, nil if unreadable.
    static func msSinceProcessStart() -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let startSec = TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000
        let elapsed = Date().timeIntervalSince1970 - startSec
        return elapsed >= 0 ? elapsed * 1000 : nil
    }
}

#if canImport(UIKit) && !os(watchOS)
/// Feeds the sampler from a CADisplayLink on the main run loop. iOS only.
final class RavensightFrameHook: NSObject {
    private let sampler: RavensightHealthSampler
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    init(sampler: RavensightHealthSampler) {
        self.sampler = sampler
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if lastTimestamp > 0 {
            sampler.offer(frameSeconds: now - lastTimestamp, at: now)
        }
        lastTimestamp = now
    }

    deinit { link?.invalidate() }
}
#endif

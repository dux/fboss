import Foundation
import Combine
import CiMobileDevice

struct iPhoneDevice: Identifiable, Equatable {
    let id: String  // UDID
    let name: String
    var isConnected: Bool = true
}

struct iPhoneApp: Identifiable, Equatable {
    let id: String  // Bundle ID
    let name: String
    let version: String
}

struct iPhoneFile: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modifiedDate: Date?
    var link: SymlinkInfo?

    func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.path == rhs.path
    }
}

/// Device discovery + shared AFC plumbing. Browsing goes through
/// iPhoneFileSource and the main browser pane; this manager only scans for
/// devices (sidebar rows) and hosts the context-explicit transfer ops used
/// by CopyManager and the adapter.
@MainActor
class iPhoneManager: ObservableObject {
    static let shared = iPhoneManager()

    @Published var devices: [iPhoneDevice] = []
    @Published var isScanning: Bool = false

    private var scanTimer: Timer?
    internal let fileManager = FileManager.default
    internal let cacheDir: URL

    private init() {
        let tmpDir = fileManager.temporaryDirectory
        cacheDir = tmpDir.appendingPathComponent("dux-file-explorer-iphone-cache")
        try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        startPeriodicScan()
    }

    func cleanup() {
        scanTimer?.invalidate()
        scanTimer = nil
    }

    // MARK: - Device Detection

    func startPeriodicScan() {
        Task { await scanForDevices() }
        scanTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.scanForDevices()
            }
        }
    }

    func stopPeriodicScan() {
        scanTimer?.invalidate()
        scanTimer = nil
    }

    func scanForDevices() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let foundDevices = await Task.detached { () -> [(String, String)] in
            var deviceList: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
            var count: Int32 = 0

            let err = idevice_get_device_list(&deviceList, &count)
            guard err == IDEVICE_E_SUCCESS, let list = deviceList else {
                return []
            }

            var results: [(String, String)] = []
            for i in 0..<Int(count) {
                if let udidPtr = list[i] {
                    let udid = String(cString: udidPtr)
                    let name = self.getDeviceNameSync(udid: udid)
                    results.append((udid, name))
                }
            }

            idevice_device_list_free(deviceList)
            return results
        }.value

        var newDevices: [iPhoneDevice] = []
        for (udid, name) in foundDevices {
            newDevices.append(iPhoneDevice(id: udid, name: name, isConnected: true))
        }

        devices = newDevices
    }

    nonisolated private func getDeviceNameSync(udid: String) -> String {
        var device: idevice_t?
        var lockdown: lockdownd_client_t?

        guard idevice_new(&device, udid) == IDEVICE_E_SUCCESS, let dev = device else {
            return "iPhone (\(udid.prefix(8))...)"
        }
        defer { idevice_free(dev) }

        guard lockdownd_client_new_with_handshake(dev, &lockdown, "FileExplorer") == LOCKDOWN_E_SUCCESS,
              let client = lockdown else {
            return "iPhone (\(udid.prefix(8))...)"
        }
        defer { lockdownd_client_free(client) }

        var namePtr: UnsafeMutablePointer<CChar>?
        if lockdownd_get_device_name(client, &namePtr) == LOCKDOWN_E_SUCCESS, let ptr = namePtr {
            let name = String(cString: ptr)
            free(ptr)
            return name
        }

        return "iPhone (\(udid.prefix(8))...)"
    }

    // Context-explicit file operations in iPhoneManagerFileOps.swift
}

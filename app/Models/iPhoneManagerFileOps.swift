import Foundation
import CiMobileDevice

extension iPhoneManager {
    // MARK: - AFC Client Helper

    /// Sets up an AFC client connection to an app's documents via house_arrest, calls the body closure, and cleans up.
    nonisolated static func withAfcClient<T>(deviceId: String, appId: String, body: (afc_client_t) throws -> T?) rethrows -> T? {
        var idev: idevice_t?
        var lockdown: lockdownd_client_t?
        var service: lockdownd_service_descriptor_t?
        var houseArrest: house_arrest_client_t?
        var afc: afc_client_t?

        guard idevice_new(&idev, deviceId) == IDEVICE_E_SUCCESS, let dev = idev else { return nil }
        defer { idevice_free(dev) }

        guard lockdownd_client_new_with_handshake(dev, &lockdown, "FileExplorer") == LOCKDOWN_E_SUCCESS,
              let lock = lockdown else { return nil }
        defer { lockdownd_client_free(lock) }

        guard lockdownd_start_service(lock, HOUSE_ARREST_SERVICE_NAME, &service) == LOCKDOWN_E_SUCCESS,
              let svc = service else { return nil }
        defer { lockdownd_service_descriptor_free(svc) }

        guard house_arrest_client_new(dev, svc, &houseArrest) == HOUSE_ARREST_E_SUCCESS,
              let haClient = houseArrest else { return nil }
        defer { house_arrest_client_free(haClient) }

        guard house_arrest_send_command(haClient, "VendDocuments", appId) == HOUSE_ARREST_E_SUCCESS else { return nil }

        var resultPlist: plist_t?
        guard house_arrest_get_result(haClient, &resultPlist) == HOUSE_ARREST_E_SUCCESS else { return nil }
        if let result = resultPlist { plist_free(result) }

        guard afc_client_new_from_house_arrest_client(haClient, &afc) == AFC_E_SUCCESS,
              let afcClient = afc else { return nil }
        defer { afc_client_free(afcClient) }

        return try body(afcClient)
    }

    nonisolated static func uploadSingleFile(_ afc: afc_client_t, localURL: URL, remotePath: String) -> Bool {
        var handle: UInt64 = 0
        guard afc_file_open(afc, remotePath, AFC_FOPEN_WRONLY, &handle) == AFC_E_SUCCESS else { return false }
        defer { afc_file_close(afc, handle) }

        guard let inputStream = InputStream(url: localURL) else { return false }
        inputStream.open()
        defer { inputStream.close() }

        do {
            try StreamTransfer.copy { buffer, capacity in
                inputStream.read(buffer, maxLength: capacity)
            } write: { buffer, count in
                var written: UInt32 = 0
                guard afc_file_write(afc, handle, buffer, UInt32(count), &written) == AFC_E_SUCCESS else {
                    throw iPhoneSourceError.transferFailed
                }
                return Int(written)
            }
        } catch {
            return false
        }

        return true
    }

    nonisolated static func deleteDirectoryRecursive(_ afc: afc_client_t, path: String) -> Bool {
        var entries: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        guard afc_read_directory(afc, path, &entries) == AFC_E_SUCCESS, let entryList = entries else {
            return false
        }
        defer { afc_dictionary_free(entryList) }

        var i = 0
        while let entry = entryList[i] {
            let name = String(cString: entry)
            i += 1
            if name == "." || name == ".." { continue }

            let fullPath = path == "/" ? "/\(name)" : "\(path)/\(name)"

            // Check if it's a directory
            var info: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
            if afc_get_file_info(afc, fullPath, &info) == AFC_E_SUCCESS, let infoList = info {
                var isDir = false
                var j = 0
                while let key = infoList[j], let value = infoList[j + 1] {
                    if String(cString: key) == "st_ifmt" && String(cString: value) == "S_IFDIR" {
                        isDir = true
                    }
                    j += 2
                }
                afc_dictionary_free(infoList)

                if isDir {
                    if !deleteDirectoryRecursive(afc, path: fullPath) {
                        return false
                    }
                } else {
                    if afc_remove_path(afc, fullPath) != AFC_E_SUCCESS {
                        return false
                    }
                }
            }
        }

        // Now remove the empty directory
        return afc_remove_path(afc, path) == AFC_E_SUCCESS
    }
}

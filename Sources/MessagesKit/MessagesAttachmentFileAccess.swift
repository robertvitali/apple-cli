import Darwin

enum MessagesAttachmentFileAccess {
    /// Synchronous so that both the observation and restoration use the calling thread.
    static func withoutMaterialization<T>(unavailable: T, _ observe: () throws -> T) rethrows -> T {
        let type = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let scope = IOPOL_SCOPE_THREAD
        let previous = getiopolicy_np(type, scope)
        guard previous >= 0 else { return unavailable }
        if previous == IOPOL_MATERIALIZE_DATALESS_FILES_OFF { return try observe() }
        guard setiopolicy_np(type, scope, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else {
            return unavailable
        }

        do {
            let observation = try observe()
            return setiopolicy_np(type, scope, previous) == 0 ? observation : unavailable
        } catch {
            _ = setiopolicy_np(type, scope, previous)
            throw error
        }
    }
}

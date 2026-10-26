@_exported import Glibc
public typealias integer_t = Int32
public typealias mach_msg_type_number_t = UInt32
public typealias task_flavor_t = Int32
public let mach_task_self_: UInt32 = 0
public let TASK_VM_INFO: Int32 = 22
public let KERN_SUCCESS: Int32 = 0
public struct task_vm_info_data_t { public var phys_footprint: UInt64 = 0; public init() {} }
public func task_info(_ task: UInt32, _ flavor: Int32, _ info: UnsafeMutablePointer<Int32>, _ count: UnsafeMutablePointer<UInt32>) -> Int32 { fatalError("Unsupported Darwin task_info reached") }
extension stat {
    public var st_mtimespec: timespec { st_mtim }
    public var st_ctimespec: timespec { st_ctim }
    public var st_atimespec: timespec { st_atim }
}

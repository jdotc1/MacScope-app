import Foundation
@_exported import PortableDarwin
extension ProcessInfo {
    public enum ThermalState { case nominal, fair, serious, critical }
    public var thermalState: ThermalState { .nominal }
    public var isLowPowerModeEnabled: Bool { false }
}

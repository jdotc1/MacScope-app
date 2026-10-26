import Foundation

try DSTokenExport.write(to: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
print("wrote design tokens to \(CommandLine.arguments[1])")

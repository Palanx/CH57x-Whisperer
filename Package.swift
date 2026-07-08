// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ch57x-whisperer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ch57x-whisperer",
            // embed Info.plist so the menu bar shows "CH57x Whisperer"
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist", "-Xlinker", "Info.plist",
            ])]
        )
    ]
)

#!/usr/bin/env swift
//
// 「窗口真的出现了吗」的可执行答案。
//
// 打包脚本能证明 bundle 组装对了，`pgrep` 能证明进程活着，但两者都不能证明
// **屏幕上真的有一个窗口** —— 而这正是「不是又一个 Electron 壳」这条支柱的
// 最低验收线。这里用 CGWindowList 列出某个进程的在屏窗口与几何。
//
// 只读 ownerName / bounds / layer，不读 kCGWindowName：窗口标题需要「屏幕
// 录制」权限，而所有者与几何不需要 —— 无人值守验证不该卡在权限弹窗上。
//
// 用法：scripts/window-probe.swift dsh-studio
//
import CoreGraphics
import Foundation

let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dsh-studio"
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("window-probe: CGWindowListCopyWindowInfo returned nil\n".utf8))
    exit(2)
}

var found = 0
for window in windows {
    guard let name = window[kCGWindowOwnerName as String] as? String, name == owner else { continue }
    let pid = window[kCGWindowOwnerPID as String] as? Int ?? -1
    let layer = window[kCGWindowLayer as String] as? Int ?? -1
    let alpha = window[kCGWindowAlpha as String] as? Double ?? -1
    var rect = CGRect.zero
    if let bounds = window[kCGWindowBounds as String] as? [String: Any],
       let dict = bounds as CFDictionary?,
       let parsed = CGRect(dictionaryRepresentation: dict) {
        rect = parsed
    }
    found += 1
    print("window owner=\(name) pid=\(pid) layer=\(layer) alpha=\(alpha) "
        + "bounds=\(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.width))x\(Int(rect.height))")
}

if found == 0 {
    print("no on-screen window owned by `\(owner)`")
    exit(1)
}
print("on-screen windows owned by `\(owner)`: \(found)")

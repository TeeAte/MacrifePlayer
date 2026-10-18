// main.swift
// 模块级全局变量
//         MetalPlayer.app      : __C.NSApplication
//         MetalPlayer.delegate : MetalPlayer.AppDelegate
//
// 这两个变量的存在说明**入口是手写的 main.swift**，而不是 nib / @NSApplicationMain：
// 后两者的实现方式不会在符号表里留下这两个变量。
//
// 推断实现（非二进制恢复）: main.swift 的原文未恢复，下面是等价形态。
//
// 为什么不能改用 @main —— 这是「Dock 有图标但没有窗口」的根因：
//   @main 作用在 NSApplicationDelegate 上时，等价于调用 NSApplicationMain()，
//   而 NSApplicationMain() 只会从 Info.plist 的 NSMainNibFile 加载 delegate 装配。
//   本工程没有 nib，于是 NSApplication.shared.delegate 始终是 nil，
//   applicationDidFinishLaunching(_:) 永远不会被调用 —— 进程活着、驱动着 Dock 图标，
//   但没有任何代码去创建 NSWindow。

import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

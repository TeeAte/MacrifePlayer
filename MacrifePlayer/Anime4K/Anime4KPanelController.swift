// Anime4KPanelController.swift
// Macrife Player · Phase 5 Anime4K 动漫滤镜与画质配置面板

import Foundation
import AppKit

final class Anime4KPanelController: NSWindowController {

    static let shared = Anime4KPanelController()

    // MARK: - 控件

    private let enableSwitch = NSButton(checkboxWithTitle: "启用 Anime4K 动漫二次元增强", target: nil, action: nil)
    private let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sharpnessSlider = NSSlider(value: 1.0, minValue: 0.0, maxValue: 2.0, target: nil, action: nil)
    private let sharpnessLabel = NSTextField(labelWithString: "1.00x")

    private let denoiseSlider = NSSlider(value: 0.5, minValue: 0.0, maxValue: 1.0, target: nil, action: nil)
    private let denoiseLabel = NSTextField(labelWithString: "0.50")

    private let statusIndicator = NSTextField(labelWithString: "● 参数已实时生效")
    private let resetButton = NSButton(title: "恢复默认", target: nil, action: nil)
    private let doneButton = NSButton(title: "完成", target: nil, action: nil)

    private var isUpdatingUI = false

    // MARK: - 初始化

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 380),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.t("anime4k_panel_title")
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow

        super.init(window: panel)

        setupUI()
        loadFromSettings()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 方法

    func applyAction() {
        applySettings()
    }

    func presetChanged() {
        guard !isUpdatingUI else { return }
        applySettings()
    }

    // MARK: - UI 构建

    private func setupUI() {
        guard let panel = window else { return }

        let root = NSView(frame: panel.contentView?.bounds ?? .zero)
        root.autoresizingMask = [.width, .height]
        panel.contentView = root

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        // 标题说明
        let headerLabel = NSTextField(labelWithString: "Anime4K 针对动漫与二次元画质进行线稿边缘细化、暗化收敛与平坦区降噪，带来接近原画矢量的视觉体验。")
        headerLabel.font = .systemFont(ofSize: 12)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.lineBreakMode = .byWordWrapping
        headerLabel.maximumNumberOfLines = 3
        stack.addArrangedSubview(headerLabel)
        headerLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true

        // 开关
        enableSwitch.font = .systemFont(ofSize: 13, weight: .semibold)
        enableSwitch.target = self
        enableSwitch.action = #selector(onToggleEnable(_:))
        stack.addArrangedSubview(enableSwitch)

        // 预设选择
        let presetRow = NSStackView()
        presetRow.orientation = .horizontal
        presetRow.spacing = 12
        let presetTitle = NSTextField(labelWithString: "分辨率预设:")
        presetTitle.font = .systemFont(ofSize: 13, weight: .medium)
        presetTitle.widthAnchor.constraint(equalToConstant: 100).isActive = true

        presetPopup.removeAllItems()
        for p in Anime4KPresetID.allCases {
            presetPopup.addItem(withTitle: p.displayName)
            presetPopup.lastItem?.representedObject = p
        }
        presetPopup.target = self
        presetPopup.action = #selector(onPresetChanged(_:))

        presetRow.addArrangedSubview(presetTitle)
        presetRow.addArrangedSubview(presetPopup)
        stack.addArrangedSubview(presetRow)

        // 线稿锐化滑块
        let sharpRow = NSStackView()
        sharpRow.orientation = .horizontal
        sharpRow.spacing = 12
        let sharpTitle = NSTextField(labelWithString: "线稿锐化强度:")
        sharpTitle.font = .systemFont(ofSize: 13, weight: .medium)
        sharpTitle.widthAnchor.constraint(equalToConstant: 100).isActive = true

        sharpnessSlider.target = self
        sharpnessSlider.action = #selector(onSharpnessChanged(_:))
        sharpnessSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true

        sharpnessLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        sharpnessLabel.textColor = .secondaryLabelColor
        sharpnessLabel.widthAnchor.constraint(equalToConstant: 50).isActive = true

        sharpRow.addArrangedSubview(sharpTitle)
        sharpRow.addArrangedSubview(sharpnessSlider)
        sharpRow.addArrangedSubview(sharpnessLabel)
        stack.addArrangedSubview(sharpRow)

        // 降噪平滑滑块
        let denoiseRow = NSStackView()
        denoiseRow.orientation = .horizontal
        denoiseRow.spacing = 12
        let denoiseTitle = NSTextField(labelWithString: "自适应降噪:")
        denoiseTitle.font = .systemFont(ofSize: 13, weight: .medium)
        denoiseTitle.widthAnchor.constraint(equalToConstant: 100).isActive = true

        denoiseSlider.target = self
        denoiseSlider.action = #selector(onDenoiseChanged(_:))
        denoiseSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true

        denoiseLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        denoiseLabel.textColor = .secondaryLabelColor
        denoiseLabel.widthAnchor.constraint(equalToConstant: 50).isActive = true

        denoiseRow.addArrangedSubview(denoiseTitle)
        denoiseRow.addArrangedSubview(denoiseSlider)
        denoiseRow.addArrangedSubview(denoiseLabel)
        stack.addArrangedSubview(denoiseRow)

        // 底部工具条
        let bottomRow = NSStackView()
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 12
        bottomRow.distribution = .fill

        statusIndicator.font = .systemFont(ofSize: 11)
        statusIndicator.textColor = .systemGreen

        resetButton.target = self
        resetButton.action = #selector(onResetDefaults(_:))

        doneButton.target = self
        doneButton.action = #selector(onDone(_:))
        doneButton.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        bottomRow.addArrangedSubview(statusIndicator)
        bottomRow.addArrangedSubview(spacer)
        bottomRow.addArrangedSubview(resetButton)
        bottomRow.addArrangedSubview(doneButton)

        stack.addArrangedSubview(bottomRow)
        bottomRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
    }

    // MARK: - 数据同步

    func loadFromSettings() {
        isUpdatingUI = true
        defer { isUpdatingUI = false }

        let s = PlaybackSettings.shared
        enableSwitch.state = (s.anime4k == .on) ? .on : .off

        // 预设匹配
        for item in presetPopup.itemArray {
            if let p = item.representedObject as? Anime4KPresetID, p == s.anime4kPresetID {
                presetPopup.select(item)
                break
            }
        }

        sharpnessSlider.floatValue = s.anime4kSharpness
        sharpnessLabel.stringValue = String(format: "%.2fx", s.anime4kSharpness)

        denoiseSlider.floatValue = s.anime4kDenoise
        denoiseLabel.stringValue = String(format: "%.2f", s.anime4kDenoise)
    }

    private func applySettings() {
        let s = PlaybackSettings.shared
        s.anime4k = (enableSwitch.state == .on) ? .on : .off
        if let p = presetPopup.selectedItem?.representedObject as? Anime4KPresetID {
            s.anime4kPresetID = p
        }
        s.anime4kSharpness = sharpnessSlider.floatValue
        s.anime4kDenoise = denoiseSlider.floatValue
    }

    // MARK: - 事件响应

    @objc private func onToggleEnable(_ sender: NSButton) {
        applySettings()
    }

    @objc private func onPresetChanged(_ sender: NSPopUpButton) {
        presetChanged()
    }

    @objc private func onSharpnessChanged(_ sender: NSSlider) {
        sharpnessLabel.stringValue = String(format: "%.2fx", sender.floatValue)
        applySettings()
    }

    @objc private func onDenoiseChanged(_ sender: NSSlider) {
        denoiseLabel.stringValue = String(format: "%.2f", sender.floatValue)
        applySettings()
    }

    @objc private func onResetDefaults(_ sender: NSButton) {
        isUpdatingUI = true
        enableSwitch.state = .on
        presetPopup.selectItem(at: 2) // 1080p
        sharpnessSlider.floatValue = 1.0
        sharpnessLabel.stringValue = "1.00x"
        denoiseSlider.floatValue = 0.5
        denoiseLabel.stringValue = "0.50"
        isUpdatingUI = false
        applySettings()
    }

    @objc private func onDone(_ sender: NSButton) {
        applySettings()
        window?.orderOut(nil)
    }

    func togglePanel() {
        guard let w = window else { return }
        if w.isVisible {
            w.orderOut(nil)
        } else {
            loadFromSettings()
            w.center()
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

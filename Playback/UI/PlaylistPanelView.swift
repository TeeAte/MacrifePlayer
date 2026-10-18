//  PlaylistPanelView.swift
//  MetalPlayer 重建工程 —— 播放列表面板（Phase 2）
//
//  原版骨架观测到的成员方法：
//      setItems([PlaylistItem], currentIndex: Int)
//      show() / hide()
//      deleteAction()
//      tableViewSelectionDidChange(Notification)
//
//  反射段给出的控件名与回调名（都用上了）：
//      scrollView  tableView  deleteButton  playlistPanelView
//      onSelectIndex  onDeleteIndex  onMoveItem  onAppendPlaylistURLs  onClose
//
//  `onMoveItem` + `PlayerWindowController.movePlaylistItem(from:to:)` 说明**支持拖拽排序**，
//  所以表格注册了自己的拖拽类型、实现了 validateDrop / acceptDrop。

import Foundation
import AppKit

final class PlaylistPanelView: NSView {

    // MARK: 回调（名字取自反射池）

    var onSelectIndex: ((Int) -> Void)?
    var onDeleteIndex: ((Int) -> Void)?
    var onMoveItem: ((Int, Int) -> Void)?
    var onAppendPlaylistURLs: (([URL]) -> Void)?
    var onOpenPlaylist: (() -> Void)?
    var onSavePlaylist: (() -> Void)?
    var onClosePanel: (() -> Void)?

    // MARK: 子视图

    private let headerLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    let deleteButton = NSButton()
    private let openButton = NSButton()
    private let saveButton = NSButton()
    private let closeButton = NSButton()
    private let emptyLabel = NSTextField(labelWithString: "")

    // MARK: 数据

    private var items: [PlaylistItem] = []
    private var currentIndex: Int = -1

    /// `setItems` 里的程序化 `selectRowIndexes` 也会触发 `tableViewSelectionDidChange`，
    /// 用它屏蔽掉假回调，否则「刷新列表」会变成「重播当前曲」。
    /// 注意：必须是 stored property，只能放在主类体里 —— Swift 的 extension 不允许存属性。
    private var isProgrammaticSelection = false

    /// 拖拽排序用的私有类型。用 bundle ID 前缀避免与其它 view 的拖拽撞车。
    private static let rowDragType =
        NSPasteboard.PasteboardType("com.yingyejiulimeng.macrifeplayer.playlist-row")

    /// 面板宽度。原版未给出，按「够放一列长文件名」取。
    private static let panelWidth: CGFloat = 300

    // MARK: - 构造

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildUI()
    }

    // MARK: - UI

    private func buildUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 0.92).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        headerLabel.stringValue = L10n.t("playlist")
        headerLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        headerLabel.textColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        closeButton.title = L10n.t("close")
        closeButton.bezelStyle = .recessed
        closeButton.font = .systemFont(ofSize: 11)
        closeButton.target = self
        closeButton.action = #selector(closeAction(_:))
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        // 表格：两列（名字 / 副标题），第一列是主列
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = L10n.t("video")
        nameColumn.width = 160
        let detailColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("detail"))
        detailColumn.title = ""
        detailColumn.width = 120
        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(detailColumn)
        tableView.headerView = nil
        tableView.rowHeight = 34
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClick(_:))
        tableView.registerForDraggedTypes([Self.rowDragType])

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.stringValue = L10n.t("no_video_opened")
        emptyLabel.font = .systemFont(ofSize: 11.5)
        emptyLabel.textColor = NSColor(calibratedWhite: 0.55, alpha: 1)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        for (button, title, action, key) in [
            (deleteButton, L10n.t("delete_short"),
             #selector(deleteAction), ""),
            (openButton, L10n.t("open_playlist"), #selector(openAction(_:)), ""),
            (saveButton, L10n.t("save_playlist"), #selector(saveAction(_:)), ""),
        ] {
            button.title = title
            button.bezelStyle = .recessed
            button.font = .systemFont(ofSize: 11)
            button.target = self
            button.action = action
            button.keyEquivalent = key
            button.translatesAutoresizingMaskIntoConstraints = false
        }

        for v in [headerLabel, closeButton, scrollView, emptyLabel,
                  deleteButton, openButton, saveButton] {
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.panelWidth),

            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            closeButton.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 16),

            deleteButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            deleteButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            openButton.topAnchor.constraint(equalTo: deleteButton.topAnchor),
            openButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            saveButton.topAnchor.constraint(equalTo: deleteButton.topAnchor),
            saveButton.trailingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: -6),
            deleteButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    // MARK: - 数据（观测方法）

    func setItems(_ items: [PlaylistItem], currentIndex: Int) {
        self.items = items
        self.currentIndex = currentIndex
        tableView.reloadData()
        emptyLabel.isHidden = !items.isEmpty
        deleteButton.isEnabled = currentIndex >= 0 && currentIndex < items.count

        // 程序化选中要屏蔽 selectionDidChange，否则「刷新列表」会被当成「用户点了这一行」→ 重播。
        isProgrammaticSelection = true
        if currentIndex >= 0, currentIndex < items.count {
            tableView.selectRowIndexes(IndexSet(integer: currentIndex), byExtendingSelection: false)
            tableView.scrollRowToVisible(currentIndex)
        } else {
            tableView.deselectAll(nil)
        }
        isProgrammaticSelection = false
    }

    // MARK: - 显示 / 隐藏（观测方法）

    private(set) var isShown = false

    func show() {
        guard !isShown else { return }
        isShown = true
        isHidden = false
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        isHidden = true
    }

    func toggle() { isShown ? hide() : show() }

    // MARK: - 动作（观测方法 deleteAction）

    @objc func deleteAction() {
        let row = tableView.selectedRow >= 0 ? tableView.selectedRow : currentIndex
        guard row >= 0, row < items.count else { return }
        onDeleteIndex?(row)
    }

    @objc private func closeAction(_ sender: Any?) { onClosePanel?() }

    @objc private func openAction(_ sender: Any?) { onOpenPlaylist?() }

    @objc private func saveAction(_ sender: Any?) { onSavePlaylist?() }

    @objc private func tableDoubleClick(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        onSelectIndex?(row)
    }

    /// 把外部的 URL 追加进列表（由窗口控制器调用；也用于拖文件到面板上）。
    func acceptDroppedURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        onAppendPlaylistURLs?(urls)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty else {
            return false
        }
        acceptDroppedURLs(urls)
        return true
    }
}

// MARK: - 表格数据源 / 代理

extension PlaylistPanelView: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row >= 0, row < items.count else { return nil }
        let item = items[row]

        let id = NSUserInterfaceItemIdentifier("cell-\(tableColumn?.identifier.rawValue ?? "?")")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
            ?? Self.makeCell(identifier: id)

        let isCurrent = (row == currentIndex)
        cell.textField?.stringValue = tableColumn?.identifier.rawValue == "name"
            ? item.title
            : item.subtitle
        cell.textField?.textColor = isCurrent
            ? NSColor.controlAccentColor
            : (item.isMissing
               ? NSColor(calibratedWhite: 0.55, alpha: 1)
               : NSColor(calibratedWhite: 0.88, alpha: 1))
        return cell
    }

    private static func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 11.5)
        field.lineBreakMode = .byTruncatingMiddle
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// 观测方法：选中变化 → 通知外部切曲。
    /// 注意：只在**用户点击**时回调。`setItems` 里的程序化 `selectRowIndexes`
    /// 也会触发这个通知，所以用 `isProgrammaticSelection` 屏蔽掉 —— 否则
    /// 「列表刷新」会变成「重新播一遍当前曲」，是死循环。
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isProgrammaticSelection else { return }
        let row = tableView.selectedRow
        deleteButton.isEnabled = row >= 0 && row < items.count
        guard row >= 0, row < items.count, row != currentIndex else { return }
        onSelectIndex?(row)
    }

    // MARK: 拖拽排序（对应 movePlaylistItem(from:to:)）

    func tableView(_ tableView: NSTableView,
                   pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let entry = NSPasteboardItem()
        entry.setString(String(row), forType: Self.rowDragType)
        return entry
    }

    func tableView(_ tableView: NSTableView,
                   validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation)
    -> NSDragOperation {
        // 只接受「插到某行之前」，且来源必须是本表格
        guard dropOperation == .above,
              info.draggingSource as? NSTableView === tableView else { return [] }
        return .move
    }

    func tableView(_ tableView: NSTableView,
                   acceptDrop info: NSDraggingInfo,
                   row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let raw = info.draggingPasteboard.string(forType: Self.rowDragType),
              let from = Int(raw) else { return false }
        // 目标行是「插入点」，从后面往前移时要减一
        var to = row
        if from < to { to -= 1 }
        guard from != to, from >= 0, from < items.count else { return false }
        onMoveItem?(from, to)
        return true
    }
}

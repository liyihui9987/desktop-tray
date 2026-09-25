import Cocoa
import QuickLookThumbnailing
import QuickLookUI
import ServiceManagement
import ImageIO
import UniformTypeIdentifiers

// MARK: - 开机自启动

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func setEnabled(_ on: Bool) {
        if on {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
    }
}

// MARK: - 崩溃守护

/// 崩溃时写日志并自动拉起自己（同一天最多 5 次，防止启动即崩的无限循环）。
/// 不依赖 launchd 常驻进程，崩了才动作。
/// 信号处理必须在原始信号上下文里完成（释放锁 + posix_spawn + _exit），
/// 因为致命信号触发时 DispatchSource 无法保证在进程终止前执行。
enum CrashGuard {
    static let logDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/桌面托盘", isDirectory: true)
    static let maxRelaunchesPerDay = 5
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f
    }()
    /// 缓存可执行路径的 C 字符串与 argv，信号上下文里直接复用，避免任何 Swift 堆分配。
    fileprivate static var executableCString: UnsafeMutablePointer<CChar>?
    fileprivate static var relaunchCountFileCString: UnsafeMutablePointer<CChar>?
    fileprivate static var argvCache: [UnsafeMutablePointer<CChar>?] = []

    static var executablePath: String {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(size))
        defer { buffer.deallocate() }
        _ = _NSGetExecutablePath(buffer, &size)
        return String(cString: buffer)
    }

    static func install() {
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        executableCString = strdup(executablePath)
        relaunchCountFileCString = strdup(relaunchCountFile())
        // argv 预分配：信号处理函数只读取，不分配 Swift Array。
        argvCache = [executableCString, nil]

        NSSetUncaughtExceptionHandler { exception in
            CrashGuard.writeLog("NSException \(exception.name.rawValue): \(exception.reason ?? "-")\n" +
                exception.callStackSymbols.joined(separator: "\n"))
            // NSException handler 在主线程调用，不存在信号上下文限制。
            CrashGuard.relaunchAndExit()
        }
        // 致命信号：注册顶层 C 函数处理，函数内部只调用 async-signal-safe 的 C API。
        // 安装前检查今日重启次数：已达上限则不再注册信号守护，防止启动即崩的无限循环。
        guard relaunchCountToday() < maxRelaunchesPerDay else {
            writeLog("今日自动重启已达 \(maxRelaunchesPerDay) 次，本次运行不再注册信号崩溃守护")
            return
        }
        for code in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP] {
            signal(code, trayCrashSignalHandler)
        }
    }

    static func writeLog(_ text: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
        let line = "[\(stamp)] \(text)\n"
        let path = logDirectory.appendingPathComponent("crash.log").path
        if let handle = fopen(path, "a") {
            fwrite(line, 1, line.utf8.count, handle)
            fclose(handle)
        }
    }

    static func relaunchAndExit() {
        guard relaunchCountToday() < maxRelaunchesPerDay else {
            writeLog("今日自动重启已达 \(maxRelaunchesPerDay) 次，停止拉起")
            exit(1)
        }
        // 计数写失败（目录不可写/磁盘满）= 无法可靠限流：宁可不拉起，
        // 否则每个新进程都读到 0，启动即崩的版本会无限重启。
        guard bumpRelaunchCount() else {
            writeLog("重启计数写入失败，为防无限重启循环，本次不再拉起")
            exit(1)
        }
        // 拉起新进程前先释放单例锁，否则新实例会因锁被占用而直接 exit(0)。
        flock(lockFD, LOCK_UN)
        close(lockFD)
        guard let exe = executableCString else { return }
        var spawnError: pid_t = 0
        posix_spawn(&spawnError, exe, nil, nil, argvCache, environ)
        exit(1)
    }

    fileprivate static func relaunchCountFile() -> String {
        return logDirectory.appendingPathComponent("relaunch-\(dayFormatter.string(from: Date()))").path
    }

    private static func relaunchCountToday() -> Int {
        guard let text = try? String(contentsOfFile: relaunchCountFile(), encoding: .utf8),
              let count = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return 0 }
        return count
    }

    @discardableResult
    private static func bumpRelaunchCount() -> Bool {
        let newCount = relaunchCountToday() + 1
        do {
            try "\(newCount)".write(toFile: relaunchCountFile(), atomically: true, encoding: .utf8)
            return true
        } catch {
            // 写失败必须让调用方感知并停止拉起，否则「无上限保护」。
            writeLog("重启计数写入失败：\(error.localizedDescription)")
            return false
        }
    }
}

/// 信号上下文专用的每日重启计数读写：只用 open/read/write/close 等 C API。
/// Foundation 的文件 API 会在信号处理函数里分配内存/加锁，可能死锁，绝不能用；
/// 缓冲区用 withUnsafeTemporaryAllocation（栈上，不经过 malloc）。
private func crashSafeReadRelaunchCount(_ path: UnsafePointer<CChar>) -> Int? {
    let fd = open(path, O_RDONLY)
    if fd < 0 {
        // 文件不存在 = 今日尚未崩溃过，计 0；其它读取失败（权限/磁盘）= 无法可靠计数。
        return errno == ENOENT ? 0 : nil
    }
    defer { close(fd) }
    return withUnsafeTemporaryAllocation(of: CChar.self, capacity: 32) { buf -> Int? in
        let n = read(fd, buf.baseAddress, 31)
        if n <= 0 { return nil }
        var count = 0
        for i in 0..<n {
            let c = buf[i]
            guard c >= 48, c <= 57 else { break }
            count = count * 10 + Int(c - 48)
        }
        return count
    }
}

/// 写入成功（含 close）返回 true；失败/短写返回 false，调用方必须停止拉起，
/// 否则「计数永远写不进去 → 永远读到 0 → 无限重启」。
private func crashSafeWriteRelaunchCount(_ path: UnsafePointer<CChar>, _ value: Int) -> Bool {
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    if fd < 0 { return false }
    let ok = withUnsafeTemporaryAllocation(of: CChar.self, capacity: 32) { buf -> Bool in
        // 手写整数转 ASCII（低位在前再原地反转）：snprintf 是变参函数，Swift 侧不可用。
        var v = max(0, value)
        var len = 0
        repeat {
            buf[len] = CChar(48 + v % 10)
            v /= 10
            len += 1
        } while v > 0
        var i = 0
        var j = len - 1
        while i < j {
            let t = buf[i]; buf[i] = buf[j]; buf[j] = t
            i += 1
            j -= 1
        }
        return write(fd, buf.baseAddress, len) == len
    }
    return ok && close(fd) == 0
}

/// 顶层 C 信号处理函数：async-signal-safe，只调用 C 标准库 / BSD / posix_spawn。
/// 负责：检查每日重启上限、计数 +1、释放单例锁、恢复信号掩码、拉起新进程、退出。
private func trayCrashSignalHandler(_ signum: Int32) {
    // 释放单例锁，否则新实例会直接 exit(0)。
    flock(lockFD, LOCK_UN)
    close(lockFD)
    // 恢复默认信号掩码，避免子进程继承被阻塞的致命信号。
    var emptyMask: sigset_t = .init()
    sigemptyset(&emptyMask)
    pthread_sigmask(SIG_SETMASK, &emptyMask, nil)
    // 每日重启计数 +1。此前只在 NSException 路径计数，信号路径漏计会导致
    // 「启动即崩」的版本 5 次上限永不生效 → 无限重启循环。
    // 计数读/写任一步失败（目录不可写、磁盘满）都无法可靠限流：宁可不再拉起。
    if let path = CrashGuard.relaunchCountFileCString {
        switch crashSafeReadRelaunchCount(path) {
        case nil:
            _exit(1)
        case .some(let count):
            guard count < CrashGuard.maxRelaunchesPerDay,
                  crashSafeWriteRelaunchCount(path, count + 1) else { _exit(1) }
        }
    }
    // 拉起新进程（路径与 argv 已在安装阶段预分配）。
    guard let exe = CrashGuard.executableCString else { _exit(Int32(128 + Int(signum))) }
    var pid: pid_t = 0
    posix_spawn(&pid, exe, nil, nil, CrashGuard.argvCache, environ)
    _exit(Int32(128 + Int(signum)))
}

/// 文件操作失败时弹出一个阻塞式告警。自动切到主线程，避免后台线程调 UI。
/// 若此刻已有模态弹窗在跑（NSApp.modalWindow 非空），则延后到下一轮事件循环再弹，
/// 避免在 runModal 嵌套的上下文里再次 runModal 导致死锁/栈深嵌套。
private func presentFileError(_ error: Error, context: String) {
    let message = context
    let info = error.localizedDescription
    let show = {
        if NSApp.modalWindow != nil {
            DispatchQueue.main.async { GlassDialog.info(title: message, message: info) }
        } else {
            GlassDialog.info(title: message, message: info)
        }
    }
    if Thread.isMainThread {
        show()
    } else {
        DispatchQueue.main.async(execute: show)
    }
}

// MARK: - 玻璃弹窗

/// 统一的深色毛玻璃弹窗：与托盘/预览面板同一视觉语言，替代系统原生 NSAlert。
/// 模态方式与 NSAlert.runModal 相同（嵌套事件循环），阻塞调用方直到做出选择。
private enum GlassDialog {

    private final class DialogWindow: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    /// 内容视图：接管 Esc（取消）与回车（确认）。
    /// 输入框成为第一响应者后按键到不了这里，由 NSTextField 的 action/delegate 两条路补齐：
    /// Return → field.action；Esc → doCommandBy(cancelOperation)。
    private final class DialogContent: NSView, NSTextFieldDelegate {
        var onEscape: (() -> Void)?
        var onReturn: (() -> Void)?
        var buttonHandlers: [ObjectIdentifier: (Int) -> Void] = [:]
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onEscape?() }          // Esc
            else if event.keyCode == 36 { onReturn?() }     // Return
            else { super.keyDown(with: event) }
        }
        @objc func buttonClicked(_ sender: NSButton) {
            buttonHandlers[ObjectIdentifier(sender)]?(sender.tag)
        }
        /// 输入框里按回车 = 确认（单行 NSTextField 的默认动作）。
        @objc func fieldConfirmed(_ sender: NSTextField) { onReturn?() }
        /// 输入框里按 Esc = 取消（field editor 会优先询问 doCommandBy）。
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) { onEscape?(); return true }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) { onReturn?(); return true }
            return false
        }
    }

    /// 玻璃按钮：悬停增亮 + 手型光标。
    private final class GlassButton: NSButton {
        var baseBackground: NSColor = .clear
        var hoverBackground: NSColor = .clear
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: bounds,
                                           options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                           owner: self, userInfo: nil))
        }
        override func mouseEntered(with event: NSEvent) {
            layer?.backgroundColor = hoverBackground.cgColor
        }
        override func mouseExited(with event: NSEvent) {
            layer?.backgroundColor = baseBackground.cgColor
        }
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    /// 弹窗顶部装饰图标（玻璃圆徽 + SF Symbol）。
    private enum DialogIcon {
        case warning   // 红：危险操作
        case pencil    // 蓝：输入/重命名
        case info      // 蓝：提示

        var symbol: String {
            switch self {
            case .warning: return "exclamationmark.triangle.fill"
            case .pencil: return "pencil"
            case .info: return "info.circle.fill"
            }
        }
        var tint: NSColor {
            switch self {
            case .warning: return NSColor(red: 1.0, green: 0.45, blue: 0.45, alpha: 1)
            case .pencil, .info: return NSColor(red: 0.55, green: 0.70, blue: 1.0, alpha: 1)
            }
        }
    }

    /// 确认框（两按钮）。destructive 时确认按钮红色。返回是否点了确认。
    @discardableResult
    static func confirm(title: String, message: String,
                        confirmTitle: String, cancelTitle: String = "取消",
                        destructive: Bool = false) -> Bool {
        run(title: title, message: message, fieldText: nil,
            icon: destructive ? .warning : .info,
            buttons: [(confirmTitle, destructive), (cancelTitle, false)])?.0 == 0
    }

    /// 信息框（单按钮）。
    static func info(title: String, message: String, buttonTitle: String = "知道了") {
        _ = run(title: title, message: message, fieldText: nil, icon: .info,
                buttons: [(buttonTitle, false)])
    }

    /// 错误框（单按钮）。
    static func error(_ err: Error, context: String? = nil) {
        info(title: context ?? "操作失败", message: err.localizedDescription)
    }

    /// 带输入框的对话框；取消返回 nil，确认返回输入内容。
    static func prompt(title: String, message: String? = nil, text: String,
                       confirmTitle: String = "保存", cancelTitle: String = "取消") -> String? {
        guard let (index, value) = run(title: title, message: message, fieldText: text,
                                       icon: .pencil,
                                       buttons: [(confirmTitle, false), (cancelTitle, false)]),
              index == 0, let value else { return nil }
        return value
    }

    /// 构建弹窗、进入模态循环，返回 (按钮序号, 输入框内容)。
    private static func run(title: String, message: String?, fieldText: String?,
                            icon: DialogIcon?,
                            buttons: [(title: String, destructive: Bool)]) -> (Int, String?)? {
        assert(Thread.isMainThread, "GlassDialog 只能在主线程调用")
        let width: CGFloat = 300
        let inner: CGFloat = 20
        let contentW = width - inner * 2
        let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let msgFont = NSFont.systemFont(ofSize: 12)
        let buttonFont = NSFont.systemFont(ofSize: 13, weight: .semibold)

        let titleH: CGFloat = 19
        let iconSize: CGFloat = icon != nil ? 38 : 0
        let fieldH: CGFloat = fieldText != nil ? 30 : 0
        let buttonH: CGFloat = 30

        let msgPara = NSMutableParagraphStyle()
        msgPara.alignment = .center
        msgPara.lineSpacing = 2
        let msgH: CGFloat = message.flatMap {
            ceil(($0 as NSString).boundingRect(
                with: NSSize(width: contentW, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: msgFont, .paragraphStyle: msgPara]).height) + 4
        } ?? 0

        var height: CGFloat = 20
        if icon != nil { height += iconSize + 12 }
        height += titleH
        if msgH > 0 { height += 6 + msgH }
        if fieldH > 0 { height += 12 + fieldH }
        height += 16 + 1 + 12 + buttonH + 14   // 内容留白 + 分隔线 + 线下留白 + 按钮 + 底部留白

        let content = DialogContent(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.wantsLayer = true

        // 白色磨砂玻璃：hudWindow + 亮色外观 + 白色半透明垫底，照 macOS 原生亮色对话框。
        content.layer?.cornerRadius = 16
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 0.5
        content.layer?.borderColor = NSColor.white.withAlphaComponent(0.45).cgColor
        let effect = NSVisualEffectView(frame: content.bounds)
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        content.addSubview(effect)

        // 磨砂玻璃底：blur 之上垫一层白色半透明，磨砂感 + 深色文字对比度。
        let frost = NSView(frame: effect.bounds)
        frost.wantsLayer = true
        frost.layer?.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.58).cgColor
        content.addSubview(frost)

        // 自顶向下排（根 view 非 flipped，y 从底往上算）。
        var y = height - 20
        if let icon {
            y -= iconSize
            let circle = NSView(frame: NSRect(x: (width - iconSize) / 2, y: y,
                                              width: iconSize, height: iconSize))
            circle.wantsLayer = true
            circle.layer?.cornerRadius = iconSize / 2
            circle.layer?.backgroundColor = icon.tint.withAlphaComponent(0.14).cgColor
            circle.layer?.borderWidth = 1
            circle.layer?.borderColor = icon.tint.withAlphaComponent(0.28).cgColor
            content.addSubview(circle)
            let iv = NSImageView(frame: circle.bounds.insetBy(dx: 11, dy: 11))
            let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            iv.image = NSImage(systemSymbolName: icon.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg)
            iv.contentTintColor = icon.tint
            circle.addSubview(iv)
            y -= 12
        }

        y -= titleH
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = titleFont
        titleLabel.textColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        titleLabel.alignment = .center
        titleLabel.frame = NSRect(x: inner, y: y, width: contentW, height: titleH)
        content.addSubview(titleLabel)

        if let message, msgH > 0 {
            y -= 6 + msgH
            let msgLabel = NSTextField(wrappingLabelWithString: "")
            msgLabel.attributedStringValue = NSAttributedString(string: message, attributes: [
                .font: msgFont, .foregroundColor: NSColor(calibratedWhite: 0.08, alpha: 0.62),
                .paragraphStyle: msgPara])
            msgLabel.frame = NSRect(x: inner, y: y, width: contentW, height: msgH)
            content.addSubview(msgLabel)
        }

        var field: NSTextField?
        if let fieldText {
            y -= 12 + fieldH
            // 白底内嵌输入框：圆角容器 + 无边框文本，文字有留白。
            let wrap = NSView(frame: NSRect(x: inner, y: y, width: contentW, height: fieldH))
            wrap.wantsLayer = true
            wrap.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.75).cgColor
            wrap.layer?.cornerRadius = 10
            wrap.layer?.borderWidth = 1
            wrap.layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
            let f = NSTextField(string: fieldText)
            f.isBordered = false
            f.drawsBackground = false
            f.focusRingType = .none
            f.font = .systemFont(ofSize: 13)
            // 回车确认 / Esc 取消（焦点在输入框时 keyDown 到不了 DialogContent，必须走这两条）。
            f.target = content
            f.action = #selector(DialogContent.fieldConfirmed(_:))
            f.delegate = content
            f.frame = wrap.bounds.insetBy(dx: 10, dy: 6)
            wrap.addSubview(f)
            content.addSubview(wrap)
            field = f
        }

        // 分隔线 + 按钮行（等宽并排，主按钮在右）。
        let dividerY: CGFloat = 14 + buttonH + 12
        let divider = NSView(frame: NSRect(x: 0, y: dividerY, width: width, height: 1))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.10).cgColor
        content.addSubview(divider)

        var result: (Int, String?)?
        let finish: (Int) -> Void = { index in
            result = (index, field?.stringValue)
            NSApp.stopModal()
        }
        let gap: CGFloat = 10
        let bW = buttons.count > 1 ? (contentW - gap) / 2 : contentW
        var bx = inner
        for (offset, spec) in buttons.reversed().enumerated() {
            let i = buttons.count - 1 - offset
            let b = GlassButton(title: "", target: nil, action: nil)
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = 10
            b.tag = i
            b.target = content
            b.action = #selector(DialogContent.buttonClicked(_:))
            let centerPara = NSMutableParagraphStyle()
            centerPara.alignment = .center
            if spec.destructive {
                b.baseBackground = NSColor(red: 0.93, green: 0.31, blue: 0.33, alpha: 1)
                b.hoverBackground = NSColor(red: 1.0, green: 0.42, blue: 0.44, alpha: 1)
                b.attributedTitle = NSAttributedString(string: spec.title, attributes: [
                    .font: buttonFont, .foregroundColor: NSColor.white, .paragraphStyle: centerPara])
            } else if i == 0 {
                // 主按钮：实心系统蓝 + 白字（macOS 原生亮色对话框的默认强调样式）。
                b.baseBackground = NSColor.controlAccentColor
                b.hoverBackground = NSColor.controlAccentColor.withAlphaComponent(0.85)
                b.attributedTitle = NSAttributedString(string: spec.title, attributes: [
                    .font: buttonFont, .foregroundColor: NSColor.white, .paragraphStyle: centerPara])
            } else {
                b.baseBackground = NSColor.black.withAlphaComponent(0.05)
                b.hoverBackground = NSColor.black.withAlphaComponent(0.10)
                b.layer?.borderWidth = 0.5
                b.layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
                b.attributedTitle = NSAttributedString(string: spec.title, attributes: [
                    .font: buttonFont, .foregroundColor: NSColor(calibratedWhite: 0.08, alpha: 0.85),
                    .paragraphStyle: centerPara])
            }
            b.layer?.backgroundColor = b.baseBackground.cgColor
            b.frame = NSRect(x: bx, y: 14, width: bW, height: buttonH)
            content.buttonHandlers[ObjectIdentifier(b)] = finish
            content.addSubview(b)
            bx += bW + gap
        }
        content.onEscape = { finish(buttons.count - 1) }
        content.onReturn = { finish(0) }

        let panel = DialogWindow(contentRect: content.bounds,
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        panel.contentView = content
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .modalPanel
        // 钉死亮色外观：白磨砂玻璃 + 深色文字，浮在任何背景上都一致。
        panel.appearance = NSAppearance(named: .vibrantLight)
        panel.initialFirstResponder = content
        panel.center()

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        field?.selectText(nil)
        // 入场动效：淡入 + 轻微放大归位。
        panel.alphaValue = 0
        content.layer?.transform = CATransform3DMakeScale(0.96, 0.96, 1)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 1
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        content.layer?.transform = CATransform3DIdentity
        CATransaction.commit()
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return result
    }
}

// MARK: - 数据模型

struct GlassFrame: Codable, Equatable {
    let id: UUID
    var title: String
    var frame: CGRect
    // 每个托盘对应总文件夹里的一个子文件夹；名字跟随标题，但只在不冲突时才跟着改。
    var folderName: String?
    // 文件夹是唯一事实源：这里只记「文件名 → 框内位置」（canvas 坐标，上原点）。
    // 文件本身的增删以子文件夹内容为准，实时镜像。
    var positions: [String: CGPoint]
    // 拖到桌面时按文件身份保存原排列，回拖后恢复；可跨应用重启。
    var desktopReturnPositions: [String: CGPoint]?
    // 置顶名单（有序，靠前的排更前）。nil = 没有任何置顶。
    var pinnedNames: [String]?

    init(title: String, frame: CGRect, id: UUID = UUID(), folderName: String? = nil, positions: [String: CGPoint] = [:]) {
        self.id = id
        self.title = title
        self.frame = frame
        self.folderName = folderName
        self.positions = positions
        self.desktopReturnPositions = nil
        self.pinnedNames = nil
    }
}

/// 运行时的一个托盘条目 = 子文件夹里的一个真实文件/文件夹。
struct FolderEntry {
    let name: String
    let url: URL
    let modified: Date?
    /// 是否为文件夹（缓存一次，拖拽/预览多处要用）。
    var isDirectory: Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}

private extension NSPasteboard.PasteboardType {
    static let glassItem = NSPasteboard.PasteboardType("com.chuyi.glassframe.item")
}

// 拖拽从源框发起、目标框接收：相对位置必须放文件作用域，
// 放在 view 里目标框读到的是空数据，整组图标会全叠到同一个点。
private struct GlassDragContext {
    let sourceFrameID: UUID
    let grabbedName: String
    let offsets: [String: CGPoint]
    let fileIdentities: [String: String]
}
private var activeGlassDragContext: GlassDragContext?
private var glassDragConsumedByFrame = false

/// 拖放链路日志：写 ~/Library/Logs/桌面托盘/drag.log。
/// 排查「文件夹判定不跟鼠标」这类只有拖拽时才复现的问题，全靠它。
private func dropLog(_ text: String) {
    let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/桌面托盘", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let line = "[\(stamp)] \(text)\n"
    let path = dir.appendingPathComponent("drag.log").path
    // 超 512KB 轮转一次（drag.log.old 覆盖旧的），避免常年累月无限膨胀。
    if let attr = try? FileManager.default.attributesOfItem(atPath: path),
       let size = attr[.size] as? UInt64, size > 512 * 1024 {
        let old = dir.appendingPathComponent("drag.log.old").path
        try? FileManager.default.removeItem(atPath: old)
        try? FileManager.default.moveItem(atPath: path, toPath: old)
    }
    if let handle = fopen(path, "a") {
        fwrite(line, 1, line.utf8.count, handle)
        fclose(handle)
    }
}
private var lastDropHoverName: String?
private var lastHoverLogTime: TimeInterval = 0

// MARK: - Finder 桌面图标坐标

/// 拖入时读取 Finder 桌面的原始排列。
/// 需要「自动化 → Finder」权限，被拒绝时静默退化，不影响文件本身的进出。
private enum FinderDesktop {
    static func positions() -> [String: CGPoint] {
        let source = """
        tell application "Finder"
            set xs to every item of (path to desktop folder)
            set output to ""
            repeat with i in xs
                try
                    set obj to contents of i
                    set p to desktop position of obj
                    set output to output & (name of obj) & tab & (item 1 of p) & tab & (item 2 of p) & linefeed
                end try
            end repeat
            return output
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return [:] }
        guard let output = script.executeAndReturnError(nil).stringValue else { return [:] }
        var result: [String: CGPoint] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 3, let x = Double(fields[1]), let y = Double(fields[2]),
                  x >= 0, y >= 0 else { continue }
            result[fields[0]] = CGPoint(x: x, y: y)
        }
        return result
    }

    static func setPositions(_ positions: [String: CGPoint]) {
        guard !positions.isEmpty else { return }
        func literal(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let commands = positions.map { name, point in
            "try\nset desktop position of item \(literal(name)) of (path to desktop folder) to {\(Int(point.x)), \(Int(point.y))}\nend try"
        }.joined(separator: "\n")
        let script = NSAppleScript(source: "tell application \"Finder\"\n\(commands)\nend tell")
        _ = script?.executeAndReturnError(nil)
    }

}

private enum DropPlacement {
    /// 任意落点吸附到最近网格；拖放、板间移动、外部加文件统一走这里。
    static func snapToGrid(_ raw: CGPoint, width: CGFloat) -> CGPoint {
        let cell = TrayItemView.cellSize
        let left = FramePanelView.contentInset.left
        let top = FramePanelView.contentInset.top
        let right = FramePanelView.contentInset.right
        let maxCol = max(0, Int((width - left - right) / cell.width))
        let col = min(max(0, Int(round((raw.x - left) / cell.width))), maxCol)
        let row = max(0, Int(round((raw.y - top) / cell.height)))
        return CGPoint(x: left + CGFloat(col) * cell.width,
                       y: top + CGFloat(row) * cell.height)
    }

    static func layout(urls: [URL], sourcePoints: [String: CGPoint], drop: CGPoint,
                       width: CGFloat, anchorPath: String? = nil) -> [String: CGPoint] {
        let cell = TrayItemView.cellSize
        let left = FramePanelView.contentInset.left
        let top = FramePanelView.contentInset.top
        let right = FramePanelView.contentInset.right
        let maxX = max(left, width - right - cell.width)
        let paths = urls.map { $0.standardizedFileURL.path }
        guard !paths.isEmpty else { return [:] }
        let points = paths.compactMap { sourcePoints[$0] }
        let hasDistinctLayout = points.count == paths.count &&
            points.contains { a in points.contains { b in hypot(a.x - b.x, a.y - b.y) > 8 } }
        // Finder 没给出可靠的组内坐标时，轻微错开放置，保留自由位置；不擅自整理成网格。
        let originals = paths.enumerated().reduce(into: [String: CGPoint]()) { dict, pair in
            let (index, path) = pair
            dict[path] = hasDistinctLayout ? (sourcePoints[path] ?? .zero)
                                            : CGPoint(x: CGFloat(index) * 22, y: CGFloat(index) * 18)
        }
        let minX = originals.values.map(\.x).min() ?? 0
        let maxSourceX = originals.values.map(\.x).max() ?? 0
        let minY = originals.values.map(\.y).min() ?? 0
        let maxSourceY = originals.values.map(\.y).max() ?? 0
        let spanX = maxSourceX - minX
        let spanY = maxSourceY - minY
        let scaleX = spanX > 0 ? min(1, (maxX - left) / spanX) : 1
        let groupWidth = spanX * scaleX + cell.width
        let anchor = originals[anchorPath ?? ""] ?? CGPoint(x: minX + spanX / 2, y: minY + spanY / 2)
        let startX = min(max(left, drop.x - cell.width / 2 - (anchor.x - minX) * scaleX),
                         max(left, width - right - groupWidth))
        let startY = max(top, drop.y - cell.height / 2 - (anchor.y - minY))
        let maxCol = max(0, Int((width - right - left) / cell.width))
        var taken = Set<String>()
        var snapped: [String: CGPoint] = [:]
        for path in paths {
            guard let point = originals[path] else { continue }
            let rawX = startX + (point.x - minX) * scaleX
            let rawY = startY + point.y - minY
            var col = min(max(0, Int(round((rawX - left) / cell.width))), maxCol)
            var row = max(0, Int(round((rawY - top) / cell.height)))
            // 组内撞格的往右顺延，行尾换行，保证拖一组进来也是一个整齐网格。
            while taken.contains("\(col),\(row)") {
                if col < maxCol { col += 1 } else { col = 0; row += 1 }
            }
            taken.insert("\(col),\(row)")
            snapped[path] = CGPoint(x: left + CGFloat(col) * cell.width,
                                    y: top + CGFloat(row) * cell.height)
        }
        return snapped
    }
}

// MARK: - 玻璃描边（沿用现有外观，不做改动）

private final class GlassOutlineView: NSView {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let outline = NSBezierPath(roundedRect: rect, xRadius: 30, yRadius: 30)
        outline.lineWidth = 1.2
        NSColor.black.withAlphaComponent(0.23).setStroke()
        outline.stroke()

        let inner = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 29, yRadius: 29)
        inner.lineWidth = 1
        NSColor.white.withAlphaComponent(0.55).setStroke()
        inner.stroke()

        let top = NSBezierPath()
        top.move(to: NSPoint(x: rect.minX + 25, y: rect.maxY - 1))
        top.line(to: NSPoint(x: rect.maxX - 25, y: rect.maxY - 1))
        top.lineWidth = 1
        NSColor.white.withAlphaComponent(0.22).setStroke()
        top.stroke()

    }
}

// MARK: - 框选矩形

private final class MarqueeView: NSView {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        let dashed = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        dashed.lineWidth = 1
        dashed.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.75).setStroke()
        dashed.stroke()
    }
}

// MARK: - 标题胶囊与缩放手柄（沿用现有外观）

private final class ControlView: NSView {
    enum Role { case move, resize }
    let role: Role
    var title = "托盘" { didSet { needsDisplay = true } }
    var onDrag: ((NSPoint, NSRect) -> Void)?
    var onFinish: (() -> Void)?
    var currentFrame: (() -> NSRect)?
    var onRename: (() -> Void)?
    var onTidy: (() -> Void)?
    var onNewFrame: (() -> Void)?
    var onCloseFrame: (() -> Void)?
    var onChooseRoot: (() -> Void)?
    var onRevealRoot: (() -> Void)?
    var onQuit: (() -> Void)?
    var onToggleLaunchAtLogin: (() -> Void)?
    var onThumbnailScale: ((CGFloat) -> Void)?

    init(role: Role) {
        self.role = role
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if case .resize = role {
            // 保留右下角的拖拽热区，玻璃边框不再多出一块白色按钮。
            return
        }
        let pill = pillRect
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let text = NSAttributedString(string: title, attributes: attributes)
        NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 11.5, yRadius: 11.5).fill()
        text.draw(at: NSPoint(x: pill.minX + 13, y: pill.minY + 3))
    }

    /// 白色胶囊的可视范围（与 draw 里的绘制严格一致）。
    private var pillRect: NSRect {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let text = NSAttributedString(string: title, attributes: attributes)
        let size = text.size()
        return NSRect(x: (bounds.width - size.width) / 2 - 13,
                      y: (bounds.height - 23) / 2,
                      width: size.width + 26, height: 23)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if case .resize = role { return super.hitTest(point) }
        // 只有白色胶囊本体响应拖动窗口；胶囊外的标题条区域穿透给画布做框选/点选。
        return pillRect.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        if case .move = role, event.clickCount == 2 {
            onRename?()
            return
        }
        dragAnchor = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        dragStartFrame = currentFrame?() ?? .zero
    }
    private var dragAnchor: NSPoint?
    private var dragStartFrame: NSRect = .zero

    override func mouseDragged(with event: NSEvent) {
        guard let dragAnchor else { return }
        let location = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        onDrag?(NSPoint(x: location.x - dragAnchor.x, y: location.y - dragAnchor.y), dragStartFrame)
    }

    override func mouseUp(with event: NSEvent) {
        dragAnchor = nil
        onFinish?()
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        if case .move = role {
            let rename = NSMenuItem(title: "重命名标题…", action: #selector(renameTitle), keyEquivalent: "")
            rename.target = self
            menu.addItem(rename)
            let tidy = NSMenuItem(title: "整理框内图标", action: #selector(tidyIcons), keyEquivalent: "")
            tidy.target = self
            menu.addItem(tidy)
            menu.addItem(.separator())
            let newFrame = NSMenuItem(title: "新建托盘", action: #selector(newFrame), keyEquivalent: "")
            newFrame.target = self
            menu.addItem(newFrame)
            let close = NSMenuItem(title: "关闭这个托盘…", action: #selector(closeFrame), keyEquivalent: "")
            close.target = self
            menu.addItem(close)
            menu.addItem(.separator())
            let chooseRoot = NSMenuItem(title: "选择存放文件夹…", action: #selector(chooseRoot), keyEquivalent: "")
            chooseRoot.target = self
            menu.addItem(chooseRoot)
            let revealRoot = NSMenuItem(title: "打开存放文件夹", action: #selector(revealRoot), keyEquivalent: "")
            revealRoot.target = self
            menu.addItem(revealRoot)
            let launchAtLogin = NSMenuItem(title: "开机自动启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            launchAtLogin.target = self
            launchAtLogin.state = LoginItem.isEnabled ? .on : .off
            menu.addItem(launchAtLogin)
            menu.addItem(.separator())

            // 缩略图大小滑块（自定义视图）：单行布局收窄高度，菜单整体比例更紧凑。
            let scaleHolder = NSView(frame: NSRect(x: 0, y: 0, width: 208, height: 34))
            let scaleLabel = NSTextField(labelWithString: "缩略图大小")
            scaleLabel.font = .systemFont(ofSize: 11)
            scaleLabel.frame = NSRect(x: 14, y: 18, width: 100, height: 14)
            let percent = NSTextField(labelWithString: "\(Int((TrayItemView.scale * 100).rounded()))%")
            percent.font = .systemFont(ofSize: 11)
            percent.textColor = .secondaryLabelColor
            percent.alignment = .right
            percent.frame = NSRect(x: 154, y: 18, width: 40, height: 14)
            percent.tag = 1001
            let slider = NSSlider(value: Double(TrayItemView.scale), minValue: 0.6, maxValue: 2.0,
                                  target: self, action: #selector(thumbnailScaleChanged(_:)))
            slider.frame = NSRect(x: 14, y: 4, width: 180, height: 18)
            slider.isContinuous = true
            scaleHolder.addSubview(scaleLabel)
            scaleHolder.addSubview(percent)
            scaleHolder.addSubview(slider)
            let scaleItem = NSMenuItem()
            scaleItem.view = scaleHolder
            menu.addItem(scaleItem)

            menu.addItem(.separator())
        }
        let quit = NSMenuItem(title: "退出玻璃框", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func renameTitle() { onRename?() }
    @objc private func tidyIcons() { onTidy?() }
    @objc private func newFrame() { onNewFrame?() }
    @objc private func closeFrame() { onCloseFrame?() }
    @objc private func chooseRoot() { onChooseRoot?() }
    @objc private func revealRoot() { onRevealRoot?() }
    @objc private func toggleLaunchAtLogin() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
        onToggleLaunchAtLogin?()
    }
    @objc private func thumbnailScaleChanged(_ sender: NSSlider) {
        onThumbnailScale?(CGFloat(sender.doubleValue))
        // 同步更新菜单里的百分比文字。
        if let percent = sender.superview?.viewWithTag(1001) as? NSTextField {
            percent.stringValue = "\(Int((sender.doubleValue * 100).rounded()))%"
        }
    }
    @objc private func quitApp() { onQuit?() }
}

// MARK: - 托盘内图标

private final class TrayIconView: NSImageView {
    weak var dragProxy: TrayCanvasView?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // registerForDraggedTypes 语义是「替换」整个列表，传空 = 注销默认注册
        registerForDraggedTypes([])
    }
    // NSImageView 天生是图片拖放接收者：即使清了注册，AppKit 仍会把 drop 路由
    // 到它身上（表现为拖到图标上 draggingUpdated 停止、松手被吞、画布收不到）。
    // 所以干脆把自己变成转发器：全部拖放事件原样丢给画布统一判定。
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragProxy?.draggingEntered(sender) ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragProxy?.draggingUpdated(sender) ?? [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { dragProxy?.draggingExited(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { dragProxy?.performDragOperation(sender) ?? false }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { dragProxy?.concludeDragOperation(sender) }
}

private final class TrayNameLabel: NSTextField {
    weak var dragProxy: TrayCanvasView?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    // 同上：NSTextField 在部分配置下也会接收文件/文本拖放，一并转发。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([])
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragProxy?.draggingEntered(sender) ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragProxy?.draggingUpdated(sender) ?? [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { dragProxy?.draggingExited(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { dragProxy?.performDragOperation(sender) ?? false }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { dragProxy?.concludeDragOperation(sender) }
}

private final class TrayItemView: NSView {
    // 缩略图缩放：全局一份（胶囊右键菜单的滑块调节），0.6x ~ 2.0x，重启保留。
    static var scale: CGFloat {
        get { UserDefaults.standard.object(forKey: "thumbnailScale") as? CGFloat ?? 1.0 }
        set { UserDefaults.standard.set(newValue, forKey: "thumbnailScale") }
    }
    // 基准 76×82，随缩放系数变化；所有布局代码读这里即可。
    static var cellSize: CGSize { CGSize(width: 76 * scale, height: 82 * scale) }

    private(set) var entry: FolderEntry
    private weak var canvas: TrayCanvasView?
    // 缩略图加载序号：每次换图自增，回调里比对，防止旧图晚到盖掉新文件的图标（串图）。
    private var thumbnailToken = 0
    private let iconView: TrayIconView
    private let nameLabel: TrayNameLabel
    private let pinBadge: TrayNameLabel
    private var isHovering = false { didSet { refreshLook() } }
    private var hoverArea: NSTrackingArea?
    // 拖拽悬停在文件夹图标上时高亮，提示松手会进入该文件夹。
    var isDropTarget = false { didSet { refreshLook() } }

    // 窗口没激活时第一下点击也要直接落在图标上，否则得先点一下窗口才能拖。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(entry: FolderEntry, canvas: TrayCanvasView) {
        self.entry = entry
        self.canvas = canvas
        iconView = TrayIconView(image: NSWorkspace.shared.icon(forFile: entry.url.path))
        nameLabel = TrayNameLabel(labelWithString: entry.name)
        pinBadge = TrayNameLabel(labelWithString: "📌")
        super.init(frame: NSRect(origin: .zero, size: Self.cellSize))
        setupUI()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 8
        refreshLook()

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.dragProxy = canvas
        addSubview(iconView)
        loadThumbnail()

        nameLabel.font = .systemFont(ofSize: 11, weight: .medium)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 2
        nameLabel.usesSingleLineMode = false
        nameLabel.cell?.wraps = true
        nameLabel.cell?.isScrollable = false
        // 跟访达桌面图标一致：亮字配暗色柔和描边，深浅壁纸上均可读。
        let textShadow = NSShadow()
        textShadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
        textShadow.shadowBlurRadius = 3
        textShadow.shadowOffset = NSSize(width: 0, height: -1)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        nameLabel.attributedStringValue = NSAttributedString(string: entry.name, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
            .shadow: textShadow,
            .paragraphStyle: paragraph
        ])
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.dragProxy = canvas
        addSubview(nameLabel)

        pinBadge.font = .systemFont(ofSize: 9)
        pinBadge.translatesAutoresizingMaskIntoConstraints = false
        pinBadge.shadow = nil
        pinBadge.dragProxy = canvas
        addSubview(pinBadge)
        NSLayoutConstraint.activate([
            pinBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 2),
            pinBadge.topAnchor.constraint(equalTo: topAnchor, constant: 0)
        ])
        pinBadge.isHidden = true

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            // 图标占格子宽度 60%：缩放滑块改格子大小时图标自动跟随，不用重建约束。
            iconView.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.6),
            iconView.heightAnchor.constraint(equalTo: iconView.widthAnchor),

            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 1),
            nameLabel.heightAnchor.constraint(lessThanOrEqualToConstant: 28)
        ])
    }

    private func refreshLook() {
        guard let layer else { return }
        pinBadge.isHidden = !(canvas?.owner?.isPinned(entry.name) ?? false)
        let selected = canvas?.owner?.selectedKeys.contains(entry.name) ?? false
        if isDropTarget {
            layer.borderWidth = 2
            layer.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.95).cgColor
            layer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor
        } else if selected {
            layer.borderWidth = 1
            layer.borderColor = NSColor.white.withAlphaComponent(0.8).cgColor
            layer.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        } else if isHovering {
            layer.borderWidth = 0.5
            layer.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
            layer.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        } else {
            layer.borderWidth = 0
            layer.backgroundColor = NSColor.clear.cgColor
        }
    }

    func refreshSelection() { refreshLook() }

    /// 缩放滑块变化后调用：字号跟随格子，缩略图按新尺寸重取。
    func applyScale() {
        let fontSize = max(9, min(15, 11 * Self.scale))
        let textShadow = NSShadow()
        textShadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
        textShadow.shadowBlurRadius = 3
        textShadow.shadowOffset = NSSize(width: 0, height: -1)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        nameLabel.attributedStringValue = NSAttributedString(string: entry.name, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white,
            .shadow: textShadow,
            .paragraphStyle: paragraph
        ])
        loadThumbnail()
    }

    func updateEntry(_ updated: FolderEntry) {
        let changed = entry.url != updated.url || entry.modified != updated.modified
        entry = updated
        if nameLabel.stringValue != updated.name {
            nameLabel.attributedStringValue = NSAttributedString(string: updated.name,
                attributes: nameLabel.attributedStringValue.attributes(at: 0, effectiveRange: nil))
        }
        if changed {
            iconView.image = NSWorkspace.shared.icon(forFile: updated.url.path)
            loadThumbnail()
        }
    }

    func dragImage() -> NSImage {
        // 拖拽影子直接用原缩略图，保持原比例；套方形画布会把竖图拉扁变形。
        if let image = iconView.image, image.size.width > 0, image.size.height > 0 {
            return image
        }
        return NSWorkspace.shared.icon(forFile: entry.url.path)
    }

    private func loadThumbnail() {
        guard FileManager.default.fileExists(atPath: entry.url.path) else {
            alphaValue = 0.45
            return
        }
        thumbnailToken += 1
        let token = thumbnailToken
        let request = QLThumbnailGenerator.Request(
            fileAt: entry.url,
            size: CGSize(width: 96 * Self.scale, height: 96 * Self.scale),
            scale: NSScreen.main?.backingScaleFactor ?? 2.0,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            // QLThumbnailGenerator 回调在后台线程；nsImage 必须在主线程读取。
            DispatchQueue.main.async {
                guard let self, self.thumbnailToken == token else { return }
                guard let image = representation?.nsImage else { return }
                self.iconView.image = image
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func mouseDown(with event: NSEvent) {
        guard let canvas, let owner = canvas.owner else { return }
        // 点进托盘 = 桌面那边的选中让位，两边互斥。
        owner.onClearFinderSelection?()
        let down = canvas.convert(event.locationInWindow, from: nil)
        dragStartPoint = down
        dragGrabOffset = CGPoint(x: min(max(down.x - frame.minX - 12, 0), 52),
                                 y: min(max(down.y - frame.minY - 5, 0), 52))
        window?.makeFirstResponder(owner)
        let extending = event.modifierFlags.contains(.shift)
        let alreadySelected = owner.selectedKeys.contains(entry.name)
        if extending {
            owner.selectItem(entry.name, extending: true)
            pendingCollapse = false
        } else if alreadySelected {
            // 按在已选中的图标上先保住整组选区，mouseUp 再收敛，否则框选永远拖不出一组。
            pendingCollapse = true
        } else {
            owner.selectItem(entry.name)
            pendingCollapse = false
        }
        if event.clickCount == 2 {
            pendingCollapse = false
            owner.openItem(entry.name)
        }
    }
    private var pendingCollapse = false
    private var isDraggingOut = false
    private var dragGrabOffset = CGPoint(x: 26, y: 26)
    private var dragStartPoint = CGPoint.zero

    override func mouseDragged(with event: NSEvent) {
        guard let canvas, !isDraggingOut else { return }
        // 点击选中时手部微抖不该惊动 Finder：位移超过阈值才发起拖拽会话。
        let cursor = canvas.convert(event.locationInWindow, from: nil)
        guard hypot(cursor.x - dragStartPoint.x, cursor.y - dragStartPoint.y) >= 4 else { return }
        guard let owner = canvas.owner else { return }
        isDraggingOut = true
        pendingCollapse = false
        let names: [String]
        if entry.isDirectory {
            names = owner.selectedKeys.contains(entry.name) ? Array(owner.selectedKeys) : [entry.name]
        } else {
            // 抓的是文件：把框选时误带上的文件夹剔出拖拽组——否则文件夹图标会跟着
            // 鼠标当「残影」，拖进文件夹时还会把目标文件夹自己搅进组里。
            let picked = owner.selectedKeys.contains(entry.name) ? owner.selectedKeys : [entry.name]
            names = picked.filter { name in
                name == entry.name ||
                owner.entries.first(where: { $0.name == name })?.isDirectory != true
            }
        }
        let items = owner.entries.filter { names.contains($0.name) }
            .sorted {
                let aGrabbed = $0.name == entry.name
                let bGrabbed = $1.name == entry.name
                if aGrabbed != bGrabbed { return aGrabbed }
                return $0.name < $1.name
            }
        guard !items.isEmpty else {
            isDraggingOut = false
            return
        }
        owner.beginItemDrag(items, grabbedName: entry.name)
        let grabbedOrigin = owner.itemOrigin(for: entry.name) ?? .zero
        let dragItems = items.map { dragged -> NSDraggingItem in
            let dragItem = NSDraggingItem(pasteboardWriter: dragged.url as NSURL)
            let image = owner.dragImage(for: dragged.name)
            let origin = owner.itemOrigin(for: dragged.name) ?? .zero
            // 影子沿用框内缩略图的比例和视觉尺寸，拖出瞬间不再缩成正方形。
            var dragSize = NSSize(width: 68, height: 68)
            let img = image
            if img.size.width > 0, img.size.height > 0 {
                let ratio = img.size.width / img.size.height
                if ratio > 1 {
                    dragSize.height = min(dragSize.height, dragSize.width / ratio)
                } else if ratio > 0 {
                    dragSize.width = min(dragSize.width, dragSize.height * ratio)
                }
            }
            dragItem.setDraggingFrame(NSRect(x: cursor.x - dragGrabOffset.x + origin.x - grabbedOrigin.x,
                                             y: cursor.y - dragGrabOffset.y + origin.y - grabbedOrigin.y,
                                             width: dragSize.width, height: dragSize.height), contents: image)
            return dragItem
        }
        glassDragConsumedByFrame = false
        // frame 是 canvas 坐标，拖拽会话也必须由同一个 canvas 发起。
        let session = canvas.beginDraggingSession(with: dragItems, event: event, source: canvas)
        session.draggingFormation = .none
    }

    override func mouseUp(with event: NSEvent) {
        isDraggingOut = false
        guard pendingCollapse else { return }
        pendingCollapse = false
        canvas?.owner?.selectItem(entry.name)
    }

    func finishDragging() { isDraggingOut = false }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let canvas, let owner = canvas.owner else { return nil }
        if owner.selectedKeys.contains(entry.name) {
            owner.contextItemName = entry.name
            return owner.itemMenu()
        }
        owner.selectItem(entry.name)
        owner.contextItemName = entry.name
        return owner.itemMenu()
    }
}

// MARK: - 框内画布

private final class TrayCanvasView: NSView, NSDraggingSource {
    weak var owner: FramePanelView?
    private var marqueeStart: NSPoint?
    private var marqueeBaseIDs: Set<String> = []
    let marqueeView = MarqueeView(frame: .zero)

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setup() {
        marqueeView.isHidden = true
        addSubview(marqueeView)
        registerForDraggedTypes([.fileURL, .glassItem, .png, .tiff])
    }

    override func mouseDown(with event: NSEvent) {
        owner?.onClearFinderSelection?()
        window?.makeFirstResponder(owner)
        let location = convert(event.locationInWindow, from: nil)
        let extending = event.modifierFlags.contains(.shift)
        if extending {
            marqueeBaseIDs = owner?.selectedKeys ?? []
        } else {
            owner?.selectItem(nil)
            marqueeBaseIDs = []
        }
        marqueeStart = location
        marqueeView.frame = NSRect(origin: location, size: .zero)
        marqueeView.isHidden = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = marqueeStart else { return }
        let location = convert(event.locationInWindow, from: nil)
        let rect = NSRect(x: min(start.x, location.x), y: min(start.y, location.y),
                          width: abs(location.x - start.x), height: abs(location.y - start.y))
        marqueeView.frame = rect
        owner?.updateMarqueeSelection(rect: rect, baseIDs: marqueeBaseIDs)
    }

    override func mouseUp(with event: NSEvent) {
        marqueeStart = nil
        marqueeView.isHidden = true
    }

    override func rightMouseDown(with event: NSEvent) {
        owner?.selectItem(nil)
        let menu = owner?.backgroundMenu() ?? NSMenu()
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pasteboard = sender.draggingPasteboard
        if pasteboard.types?.contains(.glassItem) == true { return .move }
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if urls.isEmpty {
            // 别的 App 拖纯图片数据进来（GPT 窗口、浏览器等），按拷贝接收。
            if pasteboard.types?.contains(.png) == true ||
                pasteboard.types?.contains(.tiff) == true { return .copy }
            return []
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path + "/"
        let library = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library").path + "/"
        return urls.allSatisfy { $0.standardizedFileURL.path.hasPrefix(home) &&
            !$0.standardizedFileURL.path.hasPrefix(library) } ? .move : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        // 鼠标扫过图标/标签等子视图边界时 AppKit 也会发 draggingExited（假退出），
        // 此时鼠标仍在画布内——只有真正拖出画布才清目标文件夹，否则高亮会闪。
        if let sender, bounds.contains(convert(sender.draggingLocation, from: nil)) {
            return
        }
        dropLog("[\(owner?.frameModel.title ?? "?")] exited real")
        owner?.clearDropTargetState()
    }

    // 松手收尾：无论落到哪个分支，高亮都必须清掉，否则残留在上次的文件夹上，
    // 看起来就像「判定不跟鼠标」。
    private var performedDropThisSession = false

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        let performed = performedDropThisSession
        performedDropThisSession = false
        let sticky = owner?.pendingRescueFolderName
        dropLog("[\(owner?.frameModel.title ?? "?")] concluded performed=\(performed) sticky=\(sticky ?? "nil")")
        owner?.clearDropTargetState()
        // 兜底：AppKit 偶发吞掉外部拖拽的松手（performDragOperation 没被调用，
        // drag.log 里只有 hover 没有 drop），但悬停已经命中了某个文件夹——
        // 把粘贴板里的真实文件直接搬进去，别让拖拽凭空消失。
        // 内部条目拖拽（带 .glassItem）由 draggingSession:endedAt 的救援负责，这里跳过。
        guard !performed, let sender, let owner, let sticky,
              sender.draggingPasteboard.types?.contains(.glassItem) != true else { return }
        let point = convert(sender.draggingLocation, from: nil)
        guard bounds.contains(point) else { return }
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        dropLog("[\(owner.frameModel.title)] rescueExternal into=\(sticky) count=\(urls.count)")
        owner.onImportIntoFolder?(urls, sticky)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        // 悬停高亮和松手落盘共用 dropFolderTarget（含粘性缓冲），所见即所得。
        let point = convert(sender.draggingLocation, from: nil)
        let hitName = owner?.dropFolderTarget(at: point)?.name
        let now = Date().timeIntervalSince1970
        if hitName != lastDropHoverName || now - lastHoverLogTime > 0.25 {
            lastDropHoverName = hitName
            lastHoverLogTime = now
            dropLog("[\(owner?.frameModel.title ?? "?")] hover point=(\(Int(point.x)),\(Int(point.y))) folder=\(hitName ?? "nil")")
        }
        owner?.setDropTargetFolder(hitName)
        let pasteboard = sender.draggingPasteboard
        if pasteboard.types?.contains(.glassItem) == true { return .move }
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if urls.isEmpty {
            if pasteboard.types?.contains(.png) == true ||
                pasteboard.types?.contains(.tiff) == true { return .copy }
            return []
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path + "/"
        let library = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library").path + "/"
        return urls.allSatisfy { $0.standardizedFileURL.path.hasPrefix(home) &&
            !$0.standardizedFileURL.path.hasPrefix(library) } ? .move : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        performedDropThisSession = true
        let pasteboard = sender.draggingPasteboard
        let dropPoint = convert(sender.draggingLocation, from: nil)
        // 松手点压在哪个图标上：是文件夹就变成「放进文件夹」语义。
        // 与悬停高亮同一判定函数（含粘性缓冲），高亮谁就进谁。
        let targetFolder = owner?.dropFolderTarget(at: dropPoint)
        dropLog("[\(owner?.frameModel.title ?? "?")] drop point=(\(Int(dropPoint.x)),\(Int(dropPoint.y))) target=\(targetFolder?.name ?? "nil") types=\(pasteboard.types?.map(\.rawValue).joined(separator: ",") ?? "nil")")

        let payloads = pasteboard.pasteboardItems?.compactMap { $0.string(forType: .glassItem) } ?? []
        if !payloads.isEmpty {
            var sourceFrameID: UUID?
            var names: [String] = []
            for raw in payloads {
                // "frameUUID|文件名"。文件名几乎不可能带 "|"；万一带了，这段只影响玻璃框间拖拽。
                let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2,
                      let parsedFrame = UUID(uuidString: String(parts[0])) else { continue }
                if sourceFrameID == nil { sourceFrameID = parsedFrame }
                guard sourceFrameID == parsedFrame else { continue }
                names.append(String(parts[1]))
            }
            if let sourceFrameID, !names.isEmpty {
                // 落在文件夹图标上：整组挪进那个文件夹（跨托盘也一样）。
                // 目标文件夹自己若在选中组里（同托盘多选拖拽），剔除它，其余照常进文件夹——
                // 之前因组里含目标文件夹直接放弃，整组原地重摆，图标全叠在一起。
                // 只在源、目标同托盘时按名字剔除：跨托盘拖拽时源列表不可能含本托盘的
                // 文件夹，按名字剔除会误伤恰好同名的文件。
                if let target = targetFolder {
                    let movable = sourceFrameID == owner?.frameModel.id
                        ? names.filter { $0 != target.name }
                        : names
                    if !movable.isEmpty {
                        glassDragConsumedByFrame = true
                        owner?.setDropTargetFolder(nil)
                        owner?.onMoveItemsIntoFolder?(movable, target.name, sourceFrameID)
                        return true
                    }
                }
                glassDragConsumedByFrame = true
                let context = activeGlassDragContext
                var positions: [String: CGPoint] = [:]
                for name in names {
                    let offset = context?.offsets[name] ?? .zero
                    positions[name] = DropPlacement.snapToGrid(
                        CGPoint(x: max(4, dropPoint.x + offset.x),
                                y: max(4, dropPoint.y + offset.y)),
                        width: bounds.width
                    )
                }
                owner?.onMoveItems?(names, sourceFrameID, owner?.frameModel.id ?? sourceFrameID, positions)
                return true
            }
        }

        // 别的 App 直接拖图进来（GPT 窗口、浏览器等）：粘贴板上只有图片数据没有文件地址，
        // 先落成 PNG 临时文件，再走同一条导入管线搬进托盘子文件夹。
        // 注意 Chromium 拖拽带 promised-file-url（承诺文件，此刻并不存在），
        // 必须过滤掉只认真实存在的文件，否则会误走文件分支静默失败。
        let fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if fileURLs.isEmpty, let owner, let folder = owner.frameFolderURL {
            // Chromium/GPT 拖图：优先直读粘贴板原始图片数据，NSImage 兜底。
            var payloads: [Data] = []
            if let png = pasteboard.data(forType: .png) { payloads.append(png) }
            if payloads.isEmpty, let tiff = pasteboard.data(forType: .tiff) { payloads.append(tiff) }
            if payloads.isEmpty {
                let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage] ?? []
                payloads = images.compactMap(\.tiffRepresentation)
            }
            // 统一转 PNG：已是 PNG 原样保留，TIFF/其它经 NSBitmapImageRep 重编码。
            var pngs: [Data] = []
            for data in payloads {
                if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
                    pngs.append(data)
                } else if let rep = NSBitmapImageRep(data: data),
                          let png = rep.representation(using: .png, properties: [:]) {
                    pngs.append(png)
                }
            }
            dropLog("[\(owner.frameModel.title)] imageBranch payloads=\(payloads.count) pngs=\(pngs.count) target=\(targetFolder?.name ?? "nil")")
            guard !pngs.isEmpty else { return false }

            var tempURLs: [URL] = []
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            for (index, data) in pngs.enumerated() {
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("托盘拖入-\(stamp)-\(index).png")
                do {
                    try data.write(to: temp)
                    tempURLs.append(temp)
                } catch {
                    dropLog("[\(owner.frameModel.title)] imageBranch write FAIL[\(index)] \(error.localizedDescription)")
                }
            }
            // 图片数据落在文件夹图标上：写好的临时 PNG 直接挪进那个文件夹。
            if let target = targetFolder, !tempURLs.isEmpty {
                dropLog("[\(owner.frameModel.title)] imageDrop intoFolder=\(target.name) count=\(tempURLs.count)")
                owner.clearDropTargetState()
                owner.onImportIntoFolder?(tempURLs, target.name)
                return true
            }
            var incoming: [(original: URL, final: URL, position: CGPoint)] = []
            for (index, temp) in tempURLs.enumerated() {
                let finalURL = owner.onImportURL?(temp, owner.frameModel) ?? temp
                let landed = finalURL.deletingLastPathComponent().standardizedFileURL.path ==
                    folder.standardizedFileURL.path
                dropLog("[\(owner.frameModel.title)] imageBranch importURL[\(index)] landed=\(landed) -> \(finalURL.lastPathComponent)")
                guard landed else { continue }
                let drop = DropPlacement.snapToGrid(
                    CGPoint(x: dropPoint.x + CGFloat(index) * 24,
                            y: dropPoint.y + CGFloat(index) * 18),
                    width: bounds.width)
                incoming.append((temp, finalURL, drop))
            }
            guard !incoming.isEmpty else { return false }
            owner.onImport?(incoming)
            return true
        }

        guard let rawURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], let owner else { return false }
        // Chromium 等的 promised-file-url 只是一张空头支票，只认真实存在的文件。
        let urls = rawURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return false }

        // 真实文件落在文件夹图标上：整个搬进那个文件夹，不在托盘里平铺。
        if let target = targetFolder,
           !urls.contains(where: { $0.standardizedFileURL.path == target.url.standardizedFileURL.path }) {
            owner.clearDropTargetState()
            owner.onImportIntoFolder?(urls, target.name)
            return true
        }

        // 优先保留 Finder 桌面原来的空间关系；其它来源取拖拽影子的相对位置。
        var sourcePoints: [String: CGPoint] = [:]
        let desktop = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true).standardizedFileURL.path
        let returnPoints = owner.onDesktopReturnPositions?(urls) ?? [:]
        if returnPoints.count == urls.count {
            sourcePoints = returnPoints
        } else if urls.count > 1 &&
            urls.allSatisfy({ $0.standardizedFileURL.deletingLastPathComponent().path == desktop }) {
            let desktopPositions = FinderDesktop.positions()
            for url in urls {
                sourcePoints[url.standardizedFileURL.path] = desktopPositions[url.lastPathComponent]
            }
        }
        var draggedFrames: [String: CGRect] = [:]
        sender.enumerateDraggingItems(options: [], for: self, classes: [NSURL.self],
                                      searchOptions: [.urlReadingFileURLsOnly: true]) { item, _, _ in
            guard let url = item.item as? URL else { return }
            draggedFrames[url.standardizedFileURL.path] = item.draggingFrame
        }
        if sourcePoints.count != urls.count {
            sourcePoints = draggedFrames.mapValues(\.origin)
        }
        let frameCenters = draggedFrames.mapValues { CGPoint(x: $0.midX, y: $0.midY) }
        let visibleSpread = frameCenters.values.contains { a in
            frameCenters.values.contains { b in hypot(a.x - b.x, a.y - b.y) > 8 }
        }
        let anchorPath = visibleSpread ? urls.min { a, b in
            let af = frameCenters[a.standardizedFileURL.path]
            let bf = frameCenters[b.standardizedFileURL.path]
            let ad = af.map { hypot($0.x - dropPoint.x, $0.y - dropPoint.y) } ?? .greatestFiniteMagnitude
            let bd = bf.map { hypot($0.x - dropPoint.x, $0.y - dropPoint.y) } ?? .greatestFiniteMagnitude
            return ad < bd
        }?.standardizedFileURL.path : nil
        let positions = DropPlacement.layout(
            urls: urls, sourcePoints: sourcePoints, drop: dropPoint,
            width: bounds.width,
            anchorPath: anchorPath
        )
        // 真实 I/O（同卷移动/跨卷复制）可能耗时数秒：不能在拖拽回调里同步做，
        // 否则大文件会冻结拖拽会话和整个 UI。落点布局已在上面算好，交给 App 层
        // 的串行后台队列，完成后按原布局上屏。
        owner.onImportBatch?(urls, owner.frameModel, positions,
                             owner.frameFolderURL?.standardizedFileURL.path)
        return true
    }

    // NSDraggingSource：同卷按移动；拖到外置硬盘/U 盘时目标会降级用 copy，原件保留。
    // 废纸篓协商的是 delete 操作，必须放行，否则 Dock 废纸篓永远不接收。
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.move, .copy, .delete]
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskForDraggingDestination destination: NSDraggingInfo?) -> NSDragOperation {
        [.move, .copy, .delete]
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        for (index, payload) in (owner?.activeDragPayloads ?? []).enumerated() {
            guard index < (session.draggingPasteboard.pasteboardItems?.count ?? 0),
                  let pasteboardItem = session.draggingPasteboard.pasteboardItems?[index] else { continue }
            pasteboardItem.setString("\(payload.frameID.uuidString)|\(payload.name)", forType: .glassItem)
        }
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard let owner else { return }
        dropLog("[\(owner.frameModel.title)] sessionEnded at=(\(Int(screenPoint.x)),\(Int(screenPoint.y))) op=\(operation.rawValue) items=\(owner.activeDragItems.count)")
        owner.finishItemDrag()
        let draggedItems = owner.activeDragItems
        let consumed = glassDragConsumedByFrame
        // 兜底：会话以「无操作」结束（drop 被系统吞掉，如 tooltip 垫在光标下），
        // 但松手点其实压在自家托盘的文件夹上——就地完成进文件夹，别让拖拽凭空消失。
        if operation.isEmpty, !consumed, !draggedItems.isEmpty {
            dropLog("[\(owner.frameModel.title)] rescue try at=(\(Int(screenPoint.x)),\(Int(screenPoint.y)))")
            owner.onRescueCancelledDrop?(screenPoint, draggedItems, owner.frameModel.id)
        }
        owner.activeDragPayloads.removeAll()
        owner.activeDragItems = []
        glassDragConsumedByFrame = false

        // 被自家托盘接走 = 只是换了个框；operation 为空 = 拖拽被取消，记录都必须留着。
        guard !consumed, !draggedItems.isEmpty, !operation.isEmpty else {
            activeGlassDragContext = nil
            return
        }

        // 丢到 Dock 废纸篓：系统回报 delete 操作，由我们把文件真正移进废纸篓。
        if operation == .delete {
            owner.onTrashItems?(draggedItems.map(\.name))
            activeGlassDragContext = nil
            return
        }

        // 丢到桌面或别的 App：文件离开这个托盘的子文件夹；桌面落点按原相对摆放写回。
        owner.onDraggedOut?(draggedItems, screenPoint, operation)
        activeGlassDragContext = nil
    }
}

// MARK: - 托盘面板内容

final class FramePanelView: NSView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let contentInset = NSEdgeInsets(top: 34, left: 14, bottom: 14, right: 14)

    var frameModel: GlassFrame
    // 运行时镜像的子文件夹内容（文件夹是唯一事实源）。
    var entries: [FolderEntry] = []

    var selectedKeys: Set<String> = []
    private var selectedKey: String?
    var contextItemName: String?
    var activeDragPayloads: [(frameID: UUID, name: String)] = []
    var activeDragItems: [FolderEntry] = []

    var onFrameChanged: ((GlassFrame) -> Void)?
    var onSetFrame: ((GlassFrame, NSRect) -> Void)?
    var onMoveItems: (([String], UUID, UUID, [String: CGPoint]) -> Void)?
    var onImportURL: ((URL, GlassFrame) -> URL)?
    // 批量导入（外部拖入文件的落盘走后台队列）：urls + 预算好的布局 + 目标托盘与期望落点目录。
    var onImportBatch: (([URL], GlassFrame, [String: CGPoint], String?) -> Void)?
    var frameFolderURL: URL?
    var onImport: (([(original: URL, final: URL, position: CGPoint)]) -> Void)?
    var onDraggedOut: (([FolderEntry], NSPoint, NSDragOperation) -> Void)?
    var onDesktopReturnPositions: (([URL]) -> [String: CGPoint])?
    var onReturnToDesktop: (([FolderEntry]) -> Void)?
    var onRenameItem: ((String) -> Void)?
    var onDuplicateItems: (([String]) -> Void)?
    var onNewFrame: (() -> Void)?
    var onCloseFrame: (() -> Void)?
    var onChooseRoot: (() -> Void)?
    var onRevealRoot: (() -> Void)?
    var onRename: (() -> Void)?
    var onQuit: (() -> Void)?
    var onTrashItems: (([String]) -> Void)?
    var onNewFolder: (() -> Void)?
    var onNewTextDocument: (() -> Void)?
    var onPaste: (() -> Void)?
    var onToggleLaunchAtLogin: (() -> Void)?
    var onClearFinderSelection: (() -> Void)?
    var onImportIntoFolder: (([URL], String) -> Void)?
    var onMoveItemsIntoFolder: (([String], String, UUID) -> Void)?
    var onRescueCancelledDrop: ((NSPoint, [FolderEntry], UUID) -> Void)?
    // 缩略图缩放变化后通知 App 层联动其它托盘：(新scale, 位置缩放比)。
    var onThumbnailScaleChanged: ((CGFloat, CGFloat) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49, !selectedKeys.isEmpty {
            showQuickLook()
        } else if event.keyCode == 51, !selectedKeys.isEmpty {
            // Delete/退格：把选中项移到废纸篓。
            onTrashItems?(Array(selectedKeys))
        } else {
            super.keyDown(with: event)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    private var quickLookSpaceMonitor: Any?

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
        // 从选中项开始（文件夹则从它内容的第一项开始），方向键接着往后翻。
        if let index = previewStartIndex(), !previewSequence.isEmpty {
            panel.currentPreviewItemIndex = min(index, previewSequence.count - 1)
        }
        // 面板成为 key 后按键到不了托盘视图，空格在事件层截获，保证第二次按一定关闭。
        installQuickLookSpaceMonitor()
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        removeQuickLookSpaceMonitor()
    }

    private func installQuickLookSpaceMonitor() {
        guard quickLookSpaceMonitor == nil else { return }
        quickLookSpaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 49 else { return event }
            self.removeQuickLookSpaceMonitor()
            guard let preview = QLPreviewPanel.shared() else { return event }
            if preview.isVisible {
                preview.orderOut(nil)
                return nil
            }
            return event
        }
    }

    private func removeQuickLookSpaceMonitor() {
        if let monitor = quickLookSpaceMonitor {
            NSEvent.removeMonitor(monitor)
            quickLookSpaceMonitor = nil
        }
    }

    private let canvasView = TrayCanvasView(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let glassOutline = GlassOutlineView(frame: .zero)
    private let titlePill: ControlView
    private let resizeGrip: ControlView
    private let resizeGripLeft: ControlView
    private var itemViews: [String: TrayItemView] = [:]
    // 空托盘引导文案：没有文件时显示，有文件自动消失。
    private let emptyHint: NSTextField = {
        let l = NSTextField(labelWithString: "拖文件或文件夹进来")
        l.font = .systemFont(ofSize: 13)
        l.textColor = .white.withAlphaComponent(0.35)
        l.isSelectable = false
        return l
    }()
    // 操作反馈 Toast：半透明胶囊，顶部浮入、1.6 秒后淡出。
    private var toastView: NSView?
    private var toastTimer: Timer?

    func itemOrigin(for name: String) -> CGPoint? { itemViews[name]?.frame.origin }
    func dragImage(for name: String) -> NSImage {
        itemViews[name]?.dragImage() ?? NSWorkspace.shared.icon(forFile: name)
    }
    func finishItemDrag() { itemViews.values.forEach { $0.finishDragging() } }

    init(frameModel: GlassFrame) {
        self.frameModel = frameModel
        titlePill = ControlView(role: .move)
        resizeGrip = ControlView(role: .resize)
        resizeGripLeft = ControlView(role: .resize)
        super.init(frame: NSRect(origin: .zero, size: frameModel.frame.size))
        setupUI()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupUI() {
        wantsLayer = true
        // 更圆润的边角：内容层 30pt 圆角裁剪全部子视图，玻璃描边同步用 30，
        // 窗口玻璃跟随内容形状。
        layer?.cornerRadius = 30
        layer?.masksToBounds = true
        canvasView.owner = self
        canvasView.setup()
        // 画布装进滚动容器：窗口小、图标多时上下/左右滚动查看，不用把窗口拉到巨大。
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = canvasView
        addSubview(scrollView)

        glassOutline.frame = bounds
        addSubview(glassOutline)
        emptyHint.isHidden = true
        addSubview(emptyHint)

        titlePill.title = frameModel.title
        titlePill.currentFrame = { [weak self] in self?.window?.frame ?? .zero }
        titlePill.onDrag = { [weak self] delta, start in
            self?.onSetFrame?(self?.frameModel ?? GlassFrame(title: "", frame: .zero, positions: [:]),
                              NSRect(x: start.minX + delta.x, y: start.minY + delta.y,
                                     width: start.width, height: start.height))
        }
        titlePill.onFinish = { [weak self] in self?.onFrameChanged?(self?.frameModel ?? GlassFrame(title: "", frame: .zero, positions: [:])) }
        titlePill.onRename = { [weak self] in self?.onRename?() }
        titlePill.onTidy = { [weak self] in self?.tidyIntoGrid() }
        titlePill.onNewFrame = { [weak self] in self?.onNewFrame?() }
        titlePill.onCloseFrame = { [weak self] in self?.onCloseFrame?() }
        titlePill.onChooseRoot = { [weak self] in self?.onChooseRoot?() }
        titlePill.onRevealRoot = { [weak self] in self?.onRevealRoot?() }
        titlePill.onQuit = { [weak self] in self?.onQuit?() }
        titlePill.onToggleLaunchAtLogin = { [weak self] in self?.onToggleLaunchAtLogin?() }
        titlePill.onThumbnailScale = { [weak self] scale in self?.setThumbnailScale(scale) }
        addSubview(titlePill)

        resizeGrip.currentFrame = { [weak self] in self?.window?.frame ?? .zero }
        resizeGrip.onDrag = { [weak self] delta, start in
            guard let self else { return }
            let width = max(240, start.width + delta.x)
            let height = max(180, start.height - delta.y)
            self.onSetFrame?(self.frameModel,
                             NSRect(x: start.minX, y: start.maxY - height, width: width, height: height))
        }
        resizeGrip.onFinish = { [weak self] in
            guard let self else { return }
            self.fitToWidthIfNeeded()
            self.onFrameChanged?(self.frameModel)
        }
        resizeGrip.onQuit = { [weak self] in self?.onQuit?() }
        addSubview(resizeGrip)

        // 左下角同样可以拖拽缩放：左边缘跟着鼠标走，右边钉住。
        resizeGripLeft.currentFrame = { [weak self] in self?.window?.frame ?? .zero }
        resizeGripLeft.onDrag = { [weak self] delta, start in
            guard let self else { return }
            let width = max(240, start.width - delta.x)
            let height = max(180, start.height - delta.y)
            self.onSetFrame?(self.frameModel,
                             NSRect(x: start.maxX - width, y: start.maxY - height,
                                    width: width, height: height))
        }
        resizeGripLeft.onFinish = { [weak self] in
            guard let self else { return }
            self.fitToWidthIfNeeded()
            self.onFrameChanged?(self.frameModel)
        }
        resizeGripLeft.onQuit = { [weak self] in self?.onQuit?() }
        addSubview(resizeGripLeft)

        reconcileItems()
    }

    override func layout() {
        super.layout()
        glassOutline.frame = bounds
        scrollView.frame = bounds
        let width = bounds.width
        // 标题胶囊挂在框顶；根 view 非 flipped，y 从底往上算。
        titlePill.frame = NSRect(x: 24, y: bounds.height - 24, width: max(60, width - 48), height: 24)
        resizeGrip.frame = NSRect(x: width - 46, y: 0, width: 46, height: 46)
        resizeGripLeft.frame = NSRect(x: 0, y: 0, width: 46, height: 46)
        updateCanvasContentSize()
        layoutItems()
        emptyHint.sizeToFit()
        emptyHint.frame = NSRect(x: (bounds.width - emptyHint.frame.width) / 2,
                                 y: (bounds.height - emptyHint.frame.height) / 2,
                                 width: emptyHint.frame.width, height: emptyHint.frame.height)
        layoutToast()
    }

    /// 画布作为滚动文档视图：尺寸 = 所有图标的包围盒，但不小于可视区域。
    private func updateCanvasContentSize() {
        let visible = scrollView.contentSize
        let minW = max(visible.width, bounds.width)
        let minH = max(visible.height, bounds.height)
        var maxX: CGFloat = minW
        var maxY: CGFloat = minH
        for entry in entries {
            guard let point = frameModel.positions[entry.name] else { continue }
            maxX = max(maxX, point.x + TrayItemView.cellSize.width + Self.contentInset.right)
            maxY = max(maxY, point.y + TrayItemView.cellSize.height + Self.contentInset.bottom)
        }
        canvasView.frame = NSRect(x: 0, y: 0, width: maxX, height: maxY)
    }

    // MARK: 同步（文件夹 → 图标）

    /// 数据层（FrameApp.syncFrame）算好后的整体刷新入口。
    func reload(frameModel newModel: GlassFrame, entries newEntries: [FolderEntry]) {
        frameModel = newModel
        entries = newEntries
        let validNames = Set(newEntries.map(\.name))
        selectedKeys = selectedKeys.intersection(validNames)
        if let selectedKey, !validNames.contains(selectedKey) {
            self.selectedKey = nil
        }
        titlePill.title = frameModel.title
        emptyHint.isHidden = !newEntries.isEmpty
        reconcileItems()
    }

    func applyPositions(_ positions: [String: CGPoint]) {
        frameModel.positions = positions
        layoutItems()
    }

    // MARK: 操作反馈 Toast

    /// 半透明胶囊反馈：顶部浮入，停留 1.6 秒后淡出。非模态，不打断操作。
    func showToast(_ text: String) {
        toastTimer?.invalidate()
        toastTimer = nil
        toastView?.removeFromSuperview()

        let host = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 10, height: 28))
        host.material = .hudWindow
        host.state = .active
        host.blendingMode = .behindWindow
        host.appearance = NSAppearance(named: .vibrantDark)
        host.wantsLayer = true
        host.layer?.cornerRadius = 14
        host.layer?.borderWidth = 0.5
        host.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        host.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .white
        label.sizeToFit()
        let w = max(80, min(bounds.width - 40, label.frame.width + 28))
        host.frame = NSRect(x: 0, y: 0, width: w, height: 28)
        label.frame = NSRect(x: (w - label.frame.width) / 2, y: (28 - label.frame.height) / 2,
                             width: label.frame.width, height: label.frame.height)
        host.addSubview(label)
        addSubview(host)
        toastView = host
        layoutToast()

        host.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            host.animator().alphaValue = 1
        }
        toastTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self, weak host] _ in
            guard let host, host.window != nil else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                host.animator().alphaValue = 0
            }, completionHandler: {
                host.removeFromSuperview()
                if self?.toastView === host { self?.toastView = nil }
            })
        }
    }

    private func layoutToast() {
        guard let toast = toastView else { return }
        toast.frame.origin = NSPoint(x: (bounds.width - toast.frame.width) / 2,
                                     y: bounds.height - 62)
    }

    // MARK: 图标布局（纯绝对定位）

    private func reconcileItems() {
        let valid = Set(entries.map(\.name))
        for name in itemViews.keys.filter({ !valid.contains($0) }) {
            itemViews[name]?.removeFromSuperview()
            itemViews.removeValue(forKey: name)
        }
        for entry in entries {
            if let view = itemViews[entry.name] {
                view.updateEntry(entry)
            } else {
                let view = TrayItemView(entry: entry, canvas: canvasView)
                itemViews[entry.name] = view
                canvasView.addSubview(view)
            }
        }
        layoutItems()
        refreshSelection()
    }

    private func layoutItems() {
        updateCanvasContentSize()
        for entry in entries {
            guard let view = itemViews[entry.name] else { continue }
            view.frame = NSRect(origin: frameModel.positions[entry.name] ?? .zero, size: TrayItemView.cellSize)
        }
    }

    // MARK: 选择

    func selectItem(_ name: String?, extending: Bool = false) {
        if !extending { selectedKeys.removeAll() }
        if let name {
            if extending, selectedKeys.contains(name) {
                selectedKeys.remove(name)
            } else {
                selectedKeys.insert(name)
                selectedKey = name
            }
        } else {
            selectedKey = nil
        }
        refreshSelection()
    }

    func updateMarqueeSelection(rect: NSRect, baseIDs: Set<String>) {
        var ids = baseIDs
        for (name, view) in itemViews where view.frame.intersects(rect) {
            ids.insert(name)
        }
        selectedKeys = ids
        selectedKey = ids.first
        refreshSelection()
    }

    private func refreshSelection() {
        for view in itemViews.values { view.refreshSelection() }
    }

    // MARK: 缩略图缩放

    /// 胶囊菜单滑块回调：改全局缩放，按比例重排本托盘的绝对坐标并联动其它托盘。
    func setThumbnailScale(_ newScale: CGFloat) {
        let clamped = min(max(newScale, 0.6), 2.0)
        guard abs(clamped - TrayItemView.scale) > 0.0001 else { return }
        let oldWidth = TrayItemView.cellSize.width
        TrayItemView.scale = clamped
        let ratio = TrayItemView.cellSize.width / oldWidth
        rescalePositions(by: ratio)
        onThumbnailScaleChanged?(clamped, ratio)
    }

    /// 位置是绝对坐标：格子变大后按同一比例缩放，相对布局不变。
    /// 其它托盘窗口由 App 层联动调用（scale 已全局更新，只需重排）。
    func rescalePositions(by ratio: CGFloat) {
        guard abs(ratio - 1) > 0.0001 else { return }
        for (name, p) in frameModel.positions {
            frameModel.positions[name] = CGPoint(x: p.x * ratio, y: p.y * ratio)
        }
        layoutItems()
        for view in itemViews.values { view.applyScale() }
        onFrameChanged?(frameModel)
    }

    /// 点到桌面或别的 App 时清空托盘内选中，与桌面选中互斥。
    func clearSelection() {
        selectItem(nil)
    }

    // MARK: 拖拽上下文

    /// 命中测试：落点压在哪个「文件夹」图标上（顶层最后一个命中者优先）。
    /// 判定范围向内收 12pt：格子 76 宽但可见卡片只有 ~46 宽，不收的话
    /// 鼠标看着在文件夹之间的空隙里，图标却高亮、松手还进了文件夹。
    func folderEntry(at point: CGPoint) -> FolderEntry? {
        for entry in entries.reversed() {
            guard let view = itemViews[entry.name],
                  view.frame.insetBy(dx: 12, dy: 4).contains(point) else { continue }
            let isDirectory = (try? entry.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory { return entry }
        }
        return nil
    }

    /// 任意条目（文件或文件夹）的宽松命中：压到谁头上就算谁。
    func itemEntry(at point: CGPoint) -> FolderEntry? {
        for entry in entries.reversed() {
            if let view = itemViews[entry.name],
               view.frame.insetBy(dx: 8, dy: 4).contains(point) { return entry }
        }
        return nil
    }

    /// 拖放目标文件夹的唯一真相源：悬停高亮和松手落盘都用它，保证「所见即所得」。
    /// 粘性缓冲：高亮过某个文件夹后，鼠标在它周边 16pt 内的空隙里滑动不会闪掉，
    /// 只有压到别的图标上、或真正离开缓冲区才切换/清除。
    private var stickyDropFolderName: String?

    func dropFolderTarget(at point: CGPoint) -> FolderEntry? {
        if let hit = folderEntry(at: point) {
            stickyDropFolderName = hit.name
            return hit
        }
        if itemEntry(at: point) != nil {
            // 明确压在其它条目上：目标不是文件夹。
            stickyDropFolderName = nil
            return nil
        }
        if let name = stickyDropFolderName,
           let view = itemViews[name],
           view.frame.insetBy(dx: -16, dy: -12).contains(point) {
            return entries.first(where: { $0.name == name })
        }
        stickyDropFolderName = nil
        return nil
    }

    /// 拖拽离开/结束：连粘性状态一起清。
    func clearDropTargetState() {
        stickyDropFolderName = nil
        setDropTargetFolder(nil)
    }

    /// 外部拖拽救援用：松手前最后悬停命中的文件夹（concludeDragOperation 里读）。
    var pendingRescueFolderName: String? { stickyDropFolderName }

    /// 把屏幕坐标换算进本画布，返回压中的文件夹名（不在本画布内返回 nil）。
    func dropFolderName(atScreenPoint p: NSPoint) -> String? {
        guard let win = window else { return nil }
        let windowPoint = win.convertPoint(fromScreen: p)
        let canvasPoint = canvasView.convert(windowPoint, from: nil)
        guard canvasView.bounds.contains(canvasPoint) else { return nil }
        return dropFolderTarget(at: canvasPoint)?.name
    }

    /// 拖拽悬停高亮的目标文件夹（nil = 清除）。
    func setDropTargetFolder(_ name: String?) {
        if let current = dropTargetFolderView, current.entry.name != name {
            current.isDropTarget = false
            dropTargetFolderView = nil
        }
        guard let name else { return }
        if let view = itemViews[name], view.entry.name == name {
            view.isDropTarget = true
            dropTargetFolderView = view
        }
    }

    private weak var dropTargetFolderView: TrayItemView?

    func beginItemDrag(_ items: [FolderEntry], grabbedName: String) {
        activeDragItems = items
        activeDragPayloads = items.map { (frameModel.id, $0.name) }
        guard let anchor = itemViews[grabbedName]?.frame.origin else { return }
        var offsets: [String: CGPoint] = [:]
        for item in items {
            guard let origin = itemViews[item.name]?.frame.origin else { continue }
            offsets[item.name] = CGPoint(x: origin.x - anchor.x, y: origin.y - anchor.y)
        }
        let identities = Dictionary(uniqueKeysWithValues: items.compactMap { item -> (String, String)? in
            guard let identity = FrameStore.fileIdentity(item.url) else { return nil }
            return (item.name, identity)
        })
        activeGlassDragContext = GlassDragContext(sourceFrameID: frameModel.id, grabbedName: grabbedName,
                                                 offsets: offsets, fileIdentities: identities)
    }

    // MARK: 摆放

    /// 唯一会重排的操作：按置顶优先、从上到下从左到右铺网格，行数多了自动加高框。
    func tidyIntoGrid() {
        let pitch = TrayItemView.cellSize
        let usableWidth = bounds.width - Self.contentInset.left - Self.contentInset.right
        let columns = max(1, Int(usableWidth / pitch.width))
        let fallback = CGPoint(x: CGFloat.greatestFiniteMagnitude, y: CGFloat.greatestFiniteMagnitude)
        // 清掉已不存在的置顶名（文件被删/改名后残留）。
        let validNames = Set(entries.map(\.name))
        let pinnedOrder = (frameModel.pinnedNames ?? []).filter { validNames.contains($0) }
        frameModel.pinnedNames = pinnedOrder.isEmpty ? nil : pinnedOrder
        let pinnedIndex = Dictionary(uniqueKeysWithValues: pinnedOrder.enumerated().map { ($1, $0) })
        let ordered = entries.sorted { a, b in
            switch (pinnedIndex[a.name], pinnedIndex[b.name]) {
            case let (ia?, ib?): return ia < ib
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            let pa = frameModel.positions[a.name] ?? fallback
            let pb = frameModel.positions[b.name] ?? fallback
            if abs(pa.y - pb.y) > 1 { return pa.y < pb.y }
            return pa.x < pb.x
        }
        for (index, entry) in ordered.enumerated() {
            let column = index % columns
            let row = index / columns
            frameModel.positions[entry.name] = CGPoint(
                x: Self.contentInset.left + CGFloat(column) * pitch.width,
                y: Self.contentInset.top + CGFloat(row) * pitch.height
            )
        }
        growToFitIfNeeded()
        onFrameChanged?(frameModel)
        layoutItems()
    }

    private func fitToWidthIfNeeded() {
        guard !frameModel.positions.isEmpty else { return }
        let left = Self.contentInset.left
        let limit = bounds.width - Self.contentInset.right - TrayItemView.cellSize.width
        let minX = frameModel.positions.values.map(\.x).min() ?? left
        let maxX = frameModel.positions.values.map(\.x).max() ?? left
        guard maxX > limit else { return }
        let span = maxX - minX
        let available = max(0, limit - left)
        let scale = span > available && span > 0 ? available / span : 1
        let shift = scale == 1 ? maxX - limit : 0
        for name in frameModel.positions.keys {
            guard let point = frameModel.positions[name] else { continue }
            frameModel.positions[name] = CGPoint(x: scale == 1 ? max(left, point.x - shift)
                                                           : left + (point.x - minX) * scale,
                                                 y: point.y)
        }
        layoutItems()
        onFrameChanged?(frameModel)
    }

    /// 框高度不够装下所有图标时自动加高（顶边不动）；超过屏幕高度上限就不再长，
    /// 多出来的部分靠滚动查看。
    func growToFitIfNeeded() {
        guard let maxY = frameModel.positions.values.map(\.y).max() else { return }
        let needed = maxY + TrayItemView.cellSize.height + Self.contentInset.bottom + 8
        // 高度上限：可见屏幕的 85%，避免图标一多窗口顶天立地。
        let screenLimit = (NSScreen.main?.visibleFrame.height ?? 900) * 0.85
        let target = min(needed, max(240, screenLimit))
        guard target > bounds.height else { return }
        let current = window?.frame ?? NSRect(origin: .zero, size: frameModel.frame.size)
        let newFrame = NSRect(x: current.minX, y: current.maxY - target,
                              width: current.width, height: target)
        onSetFrame?(frameModel, newFrame)
    }

    // MARK: 打开 / 菜单

    func openItem(_ name: String) {
        guard let entry = entries.first(where: { $0.name == name }),
              FileManager.default.fileExists(atPath: entry.url.path) else { return }
        NSWorkspace.shared.open(entry.url)
    }

    // MARK: 置顶

    /// 右键「置顶/取消置顶」：更新置顶名单后按网格重排，置顶项永远占据最前的格子。
    @objc private func togglePinContextItem() {
        var names: [String] = []
        if let contextItemName {
            names = selectedKeys.contains(contextItemName) ? Array(selectedKeys) : [contextItemName]
        }
        guard !names.isEmpty else { return }
        let allPinned = names.allSatisfy { frameModel.pinnedNames?.contains($0) == true }
        setPinned(names, pinned: !allPinned)
    }

    func setPinned(_ names: [String], pinned: Bool) {
        var list = frameModel.pinnedNames ?? []
        list.removeAll { names.contains($0) }
        if pinned { list.insert(contentsOf: names, at: 0) }
        frameModel.pinnedNames = list.isEmpty ? nil : list
        tidyIntoGrid()
        // 置顶角标只在 refreshLook 里刷，不主动刷一遍的话取消置顶后角标还挂着，
        // 看起来就像取消没生效。
        refreshSelection()
    }

    func isPinned(_ name: String) -> Bool {
        frameModel.pinnedNames?.contains(name) == true
    }

    func itemMenu() -> NSMenu {
        let names: [String]
        if let contextItemName {
            names = selectedKeys.contains(contextItemName) ? Array(selectedKeys) : [contextItemName]
        } else {
            names = []
        }
        let targets = entries.filter { names.contains($0.name) }
        let suffix = targets.count > 1 ? "（\(targets.count) 项）" : ""
        let menu = NSMenu()

        let open = NSMenuItem(title: "打开", action: #selector(openContextItem), keyEquivalent: "")
        open.target = self
        open.isEnabled = targets.count == 1
        menu.addItem(open)

        if let target = targets.first, targets.count == 1 {
            let apps = NSWorkspace.shared.urlsForApplications(toOpen: target.url)
            if !apps.isEmpty {
                let openWith = NSMenuItem(title: "打开方式", action: nil, keyEquivalent: "")
                let choices = NSMenu()
                for appURL in apps {
                    let name = FileManager.default.displayName(atPath: appURL.path)
                    let item = NSMenuItem(title: name, action: #selector(openContextItemWithApp(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = appURL
                    choices.addItem(item)
                }
                menu.setSubmenu(choices, for: openWith)
                menu.addItem(openWith)
            }
        }

        let preview = NSMenuItem(title: "快速查看", action: #selector(previewContextItem), keyEquivalent: "")
        preview.target = self
        preview.isEnabled = targets.count == 1
        menu.addItem(preview)
        menu.addItem(.separator())

        let allPinned = !targets.isEmpty && targets.allSatisfy { frameModel.pinnedNames?.contains($0.name) == true }
        let pin = NSMenuItem(title: allPinned ? "取消置顶" : "置顶为第一个",
                             action: #selector(togglePinContextItem), keyEquivalent: "")
        pin.target = self
        menu.addItem(pin)

        let rename = NSMenuItem(title: "重新命名", action: #selector(renameContextItem), keyEquivalent: "")
        rename.target = self
        rename.isEnabled = targets.count == 1
        menu.addItem(rename)
        let duplicate = NSMenuItem(title: "复制\(suffix)", action: #selector(duplicateContextItems), keyEquivalent: "")
        duplicate.target = self
        menu.addItem(duplicate)

        let showInFinder = NSMenuItem(title: "在 Finder 中显示", action: #selector(showContextItemInFinder), keyEquivalent: "")
        showInFinder.target = self
        menu.addItem(showInFinder)

        let copy = NSMenuItem(title: "拷贝\(suffix)", action: #selector(copyContextItems), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        menu.addItem(.separator())

        let trash = NSMenuItem(title: "移到废纸篓\(suffix)", action: #selector(trashContextItems), keyEquivalent: "")
        trash.target = self
        menu.addItem(trash)

        let remove = NSMenuItem(title: "移回桌面\(suffix)", action: #selector(removeContextItem), keyEquivalent: "")
        remove.target = self
        menu.addItem(remove)
        return menu
    }

    func backgroundMenu() -> NSMenu {
        let menu = NSMenu()
        let newFolder = NSMenuItem(title: "新建文件夹", action: #selector(newFolderFromMenu), keyEquivalent: "")
        newFolder.target = self
        menu.addItem(newFolder)
        let paste = NSMenuItem(title: "粘贴", action: #selector(pasteFromMenu), keyEquivalent: "")
        paste.target = self
        menu.addItem(paste)
        menu.addItem(.separator())
        let tidy = NSMenuItem(title: "整理", action: #selector(tidyFromMenu), keyEquivalent: "")
        tidy.target = self
        menu.addItem(tidy)
        let revealRoot = NSMenuItem(title: "在 Finder 中打开此文件夹", action: #selector(revealCurrentFolderFromMenu), keyEquivalent: "")
        revealRoot.target = self
        menu.addItem(revealRoot)
        return menu
    }

    @objc private func openContextItem() {
        guard let contextItemName else { return }
        openItem(contextItemName)
    }

    @objc private func openContextItemWithApp(_ sender: NSMenuItem) {
        guard let name = contextItemName,
              let url = entries.first(where: { $0.name == name })?.url,
              let appURL = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func renameContextItem() {
        guard let contextItemName else { return }
        onRenameItem?(contextItemName)
    }

    @objc private func duplicateContextItems() {
        guard let contextItemName else { return }
        let names = selectedKeys.contains(contextItemName) ? Array(selectedKeys) : [contextItemName]
        onDuplicateItems?(names)
    }

    @objc private func showContextItemInFinder() {
        guard let contextItemName else { return }
        let names = selectedKeys.contains(contextItemName) ? Array(selectedKeys) : [contextItemName]
        let urls = entries.filter { names.contains($0.name) }.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func previewContextItem() {
        guard let contextItemName else { return }
        if !selectedKeys.contains(contextItemName) {
            selectItem(contextItemName)
        }
        showQuickLook()
    }

    private func showQuickLook() {
        guard !selectedKeys.isEmpty else { return }
        // 文件夹（单个选中）走自绘图标网格预览：SpacePeek 扩展只在 Finder 宿主里
        // 给完整网格 UI，其它宿主只能拿到系统玻璃列表（实测反复确认）。
        // 其余类型继续走系统 Quick Look 面板。
        let selected = entries.filter { selectedKeys.contains($0.name) }
        if selected.count == 1,
           (try? selected[0].url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            FolderPreviewPanel.open(url: selected[0].url, relativeTo: window)
            return
        }
        toggleSystemQuickLook()
    }

    private func toggleSystemQuickLook() {
        guard let preview = QLPreviewPanel.shared() else { return }
        if preview.isVisible {
            preview.orderOut(nil)
            return
        }
        guard !previewSequence.isEmpty, previewStartIndex() != nil else {
            return
        }
        preview.updateController()
        NSApp.activate(ignoringOtherApps: true)
        // 托盘的 QL 面板默认尺寸偏窄，SpacePeek 的自动内容布局在窄容器里会
        // 退化成列表（Finder 的面板宽所以一直是网格）。首次打开给足宽度。
        if preview.frame.width < 800, let screen = window?.screen ?? NSScreen.main {
            let size = NSSize(width: 980, height: 660)
            let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2,
                                 y: screen.visibleFrame.midY - size.height / 2)
            preview.setFrame(NSRect(origin: origin, size: size), display: false)
        }
        preview.makeKeyAndOrderFront(nil)
    }

    static func isImageFile(_ url: URL) -> Bool {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else { return false }
        return type.conforms(to: .image)
    }
    @objc private func copyContextItems() {
        guard let contextItemName else { return }
        let names = selectedKeys.contains(contextItemName) ? Array(selectedKeys) : [contextItemName]
        let urls = entries.filter { names.contains($0.name) }.map(\.url)
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
    }

    @objc private func trashContextItems() {
        guard let contextItemName else { return }
        let names = selectedKeys.contains(contextItemName) ? Array(selectedKeys) : [contextItemName]
        onTrashItems?(names)
    }

    @objc private func removeContextItem() {
        guard let contextItemName else { return }
        let names = selectedKeys.contains(contextItemName) ? Array(selectedKeys) : [contextItemName]
        let targets = entries.filter { names.contains($0.name) }
        onReturnToDesktop?(targets)
    }

    @objc private func newFolderFromMenu() { onNewFolder?() }
    @objc private func newTextFromMenu() { onNewTextDocument?() }
    @objc private func pasteFromMenu() { onPaste?() }
    @objc private func tidyFromMenu() { tidyIntoGrid() }
    @objc private func newFrameFromMenu() { onNewFrame?() }
    @objc private func closeFrameFromMenu() { onCloseFrame?() }
    @objc private func chooseRootFromMenu() { onChooseRoot?() }
    @objc private func revealRootFromMenu() { onRevealRoot?() }
    @objc private func revealCurrentFolderFromMenu() {
        guard let frameFolderURL else { return }
        NSWorkspace.shared.open(frameFolderURL)
    }
    @objc private func quitFromMenu() { onQuit?() }

    // MARK: Quick Look（空格预览）

    // MARK: Quick Look（空格预览，Finder 式）

    private var previewSequence: [(name: String, url: URL)] {
        // 文件夹本身作为预览项：系统 QL 面板会把 public.folder 交给 SpacePeek 的
        // 文件夹扩展渲染（内容列表）；压缩包同理走 SpacePeek 的 Archive 扩展。
        entries.filter { FileManager.default.fileExists(atPath: $0.url.path) }
               .map { ($0.name, $0.url) }
    }

    /// 选中项 → 直接定位它（含文件夹本身）。
    private func previewStartIndex() -> Int? {
        let sequence = previewSequence
        guard let first = selectedKeys.first else { return nil }
        if let index = sequence.firstIndex(where: { $0.name == first }) { return index }
        return sequence.isEmpty ? nil : 0
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel) -> Int {
        previewSequence.count
    }

    func previewPanel(_ panel: QLPreviewPanel, previewItemAt index: Int) -> QLPreviewItem {
        let sequence = previewSequence
        // 越界一律夹回合法范围；把 "/" 之类占位地址丢给预览会显示成出错页。
        guard !sequence.isEmpty else { return NSURL(fileURLWithPath: NSHomeDirectory()) as NSURL }
        let clamped = max(0, min(index, sequence.count - 1))
        return sequence[clamped].url as NSURL
    }
}

// MARK: - 面板

final class TrayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - 文件夹内容网格预览

/// 图片预览视图：基于 CALayer 显示原图，GPU 直接渲染，避免 CPU draw 重采样导致的虚影/掉帧。
/// 完整显示模式：frame 恒等于可视区，`.resizeAspect` 把整图等比缩放后居中，无滚动无平移。
private final class PanImageView: NSView {
    private var cgImage: CGImage?
    var image: NSImage? {
        didSet { updateLayerContents() }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayer()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }
    private func setupLayer() {
        wantsLayer = true
        let l = CALayer()
        l.backgroundColor = NSColor.clear.cgColor
        // .resizeAspect 等比例缩放适配 frame：窗口/右栏缩放时图片居中等比变化，绝不裁切。
        // （.center 是原尺寸不缩放，frame 一变小就被裁，正是之前「渐渐裁切」的根因。）
        l.contentsGravity = .resizeAspect
        // 放大用线性保持照片平滑；缩小用三线性过滤抗锯齿。
        l.magnificationFilter = .linear
        l.minificationFilter = .trilinear
        l.isDoubleSided = false
        // 与 NSView.isFlipped 同步，避免手动替换 layer 后 Y 轴几何翻转。
        l.isGeometryFlipped = self.isFlipped
        updateLayerScale(l)
        layer = l
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let l = layer { updateLayerScale(l) }
    }

    private func updateLayerScale(_ l: CALayer) {
        // 同步 Retina scale，确保 1:1 物理像素显示，避免模糊。
        l.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
    }

    private func updateLayerContents() {
        cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        // 禁用 CALayer 换 contents 的隐式淡入淡出过渡，否则每次切图都闪一下。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = cgImage
        CATransaction.commit()
        // 某些 NSImage 源（如动态图/多帧图）拿不到 CGImage，回退到 draw(_:) 手动绘制。
        if cgImage == nil {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // CALayer 已接管时无需 CPU 绘制。
        guard cgImage == nil, let image, image.size.width > 0, image.size.height > 0 else { return }
        let b = bounds
        let scale = min(b.width / image.size.width, b.height / image.size.height)
        let w = image.size.width * scale
        let h = image.size.height * scale
        image.draw(in: NSRect(x: (b.width - w) / 2, y: (b.height - h) / 2, width: w, height: h),
                   from: .zero, operation: .sourceOver, fraction: 1)
    }
}

/// 预览用非可编辑文本视图：NSTextView 会吞掉滚轮事件却不滚动（实测），显式转交外层滚动容器。
private final class PreviewTextView: NSTextView {
    override func scrollWheel(with event: NSEvent) {
        if let sv = enclosingScrollView {
            sv.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// 预览面板外描边：与托盘玻璃同风格（深色外圈 + 白色内圈），纯展示不挡点击。
private final class PreviewOutlineView: NSView {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let outline = NSBezierPath(roundedRect: rect, xRadius: 13, yRadius: 13)
        outline.lineWidth = 1.2
        NSColor.black.withAlphaComponent(0.23).setStroke()
        outline.stroke()

        let inner = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
        inner.lineWidth = 1
        NSColor.white.withAlphaComponent(0.55).setStroke()
        inner.stroke()
    }
}

/// 大图预览栏左侧分隔条：左右拖拽调节右栏宽度（热区加宽，双箭头光标）。
private final class PreviewDividerHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?   // 传本次拖拽 deltaX
    private var lastX: CGFloat = 0
    private var tracking: NSTrackingArea?

    override func mouseDown(with event: NSEvent) {
        lastX = convert(event.locationInWindow, from: nil).x
    }
    override func mouseDragged(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        onDrag?(x - lastX)
        lastX = x
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let ta = NSTrackingArea(rect: bounds,
                                options: [.activeInKeyWindow, .cursorUpdate, .mouseEnteredAndExited],
                                owner: self)
        addTrackingArea(ta)
        tracking = ta
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
    override func mouseEntered(with event: NSEvent) { NSCursor.resizeLeftRight.push() }
    override func mouseExited(with event: NSEvent) { NSCursor.pop() }
}

/// 预览面板右下角缩放手柄：拖拽调整窗口大小，尺寸跨重启记忆。
private final class PreviewResizeHandle: NSView {
    private var startLoc: NSPoint?
    private var startFrame: NSRect?

    override func mouseDown(with event: NSEvent) {
        startLoc = NSEvent.mouseLocation
        startFrame = window?.frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startLoc, let startFrame, let window else { return }
        let loc = NSEvent.mouseLocation
        // 右下角：向右拖变宽，向下拖变高（屏幕 y 向上，鼠标下移 = loc.y 更小）。
        let width = max(560, startFrame.width + (loc.x - startLoc.x))
        let height = max(420, startFrame.height + (startLoc.y - loc.y))
        window.setFrame(NSRect(x: startFrame.minX, y: startFrame.maxY - height,
                               width: width, height: height), display: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard let window else { return }
        let size = window.frame.size
        UserDefaults.standard.set([Double(size.width), Double(size.height)], forKey: "folderPreviewSize")
        startLoc = nil
        startFrame = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        // 右下角三条斜线纹理提示可拖拽（亮玻璃上用深色才看得见）。
        NSColor.black.withAlphaComponent(0.30).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        for i in 0..<3 {
            let off = CGFloat(i) * 7
            path.move(to: NSPoint(x: bounds.maxX - 8 - off, y: bounds.minY + 3))
            path.line(to: NSPoint(x: bounds.maxX - 3, y: bounds.minY + 8 + off))
        }
        path.stroke()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }
}

/// SpacePeek 的 Quick Look 扩展只在 Finder 宿主里提供完整网格 UI（实测：同一条
/// public.folder，Finder 是「概览|内容」+图标网格，托盘等其它宿主一律拿到系统
/// 玻璃列表，扩展进程正常拉起也改不了）。所以在托盘里自绘：毛玻璃 + 大图标网格。
final class FolderPreviewPanel: NSPanel {
    static let shared = FolderPreviewPanel()
    private let root = FolderPreviewRoot()

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 640),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces]
        // 钉死亮色外观：玻璃永远是浅磨砂（跟 macOS 原生 Quick Look 一致），
        // 深色文字在任何壁纸上都有稳定对比度，不会被深色窗口/壁纸洗成看不清。
        appearance = NSAppearance(named: .vibrantLight)
        contentView = root
    }

    override var canBecomeKey: Bool { true }

    /// 统一隐藏入口：orderOut 的同时作废在途预览回调并释放图像/文本，
    /// 共享面板隐藏后不能再持有上一文件夹的大图。
    /// 所有关闭路径（空格/Esc、失焦）都必须走这里，别直接 orderOut。
    func hideAndRelease() {
        orderOut(nil)
        root.releasePreviewResources()
    }

    static func open(url: URL, relativeTo window: NSWindow?) {
        shared.root.load(folderURL: url)
        let screen = window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var frame = shared.frame
        // 尺寸跨重启记忆（缩放手柄 mouseUp 时保存）；首次用默认值。
        if let saved = UserDefaults.standard.array(forKey: "folderPreviewSize") as? [Double],
           saved.count == 2, saved[0] >= 400 {
            frame.size = NSSize(width: saved[0], height: saved[1])
        } else {
            frame.size = NSSize(width: 1040, height: 640)
        }
        frame.size.width = min(frame.size.width, visible.width - 40)
        frame.size.height = min(frame.size.height, visible.height - 40)
        frame.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
        shared.setFrame(frame, display: true)
        shared.makeKeyAndOrderFront(nil)
        shared.makeFirstResponder(shared.root)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 根视图：毛玻璃底 + 标题栏 + 滚动网格 + 右侧大图预览栏。
private final class FolderPreviewRoot: NSView {
    private let effect = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let grid = FolderPreviewGrid()
    // 右侧大图预览：网格里选中一项时显示放大缩略图 + 文件名 + 大小/日期。
    private let previewPane = NSView()
    private let previewScroll = NSScrollView()
    private let previewImage = PanImageView()
    // 文本类文件（markdown 等）的渲染预览。
    private let previewTextScroll = NSScrollView()
    private let previewTextView: NSTextView = {
        let tv = PreviewTextView()
        tv.isEditable = false
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 4, height: 4)
        return tv
    }()
    // 文档类（PDF/Word/PPT/视频等）的内嵌 Quick Look 原生视图：按原始排版高清渲染，非缩略图。
    private let previewQLView = QLPreviewView(frame: .zero, style: .compact)
    private let previewName = NSTextField(labelWithString: "")
    private let previewMeta = NSTextField(labelWithString: "")
    private let previewDivider = NSView()
    // 分隔条拖拽热区（视觉线细，热区加宽好抓）。
    private let dividerGrab = PreviewDividerHandle()
    // 最外层玻璃描边（与托盘窗口同风格）。
    private var outlineStored: NSView?
    // PDF 预览时兜底隐藏 QL 翻页玻璃圆钮的定时器。
    private var qlOverlayTimer: Timer?
    // 右栏宽度可拖拽调节（180~560，跨重启记忆）。
    private var previewWidth: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "folderPreviewWidth")
        return (180...560).contains(v) ? v : 400
    }()
    private var previewToken = 0
    // 标题栏：网格图标大小滑块。
    private let gridScaleSlider: NSSlider = {
        let s = NSSlider(value: Double(FolderPreviewGrid.iconScale), minValue: 0.7, maxValue: 2.0, target: nil, action: nil)
        s.isContinuous = true
        // 亮色玻璃上的低调灰轨道，不跟系统蓝色强调色抢视觉。
        s.trackFillColor = NSColor.black.withAlphaComponent(0.30)
        s.appearance = NSAppearance(named: .vibrantLight)
        return s
    }()
    private let gridScalePercent = NSTextField(labelWithString: "")
    // 右下角缩放手柄：拖拽调整预览面板大小。
    private let resizeHandle = PreviewResizeHandle()
    private(set) var folderURL: URL?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 1040, height: 640))
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.black.withAlphaComponent(0.16).cgColor

        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        addSubview(effect)

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        pathLabel.font = .systemFont(ofSize: 10)
        pathLabel.textColor = NSColor(calibratedWhite: 0.08, alpha: 0.5)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(titleLabel)
        addSubview(pathLabel)

        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        grid.owner = self
        scroll.documentView = grid
        addSubview(scroll)

        previewDivider.wantsLayer = true
        previewDivider.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.10).cgColor
        addSubview(previewDivider)
        // 拖拽分隔条：左右调节右栏大图宽度。
        dividerGrab.onDrag = { [weak self] dx in
            guard let self else { return }
            let maxW = max(180, self.bounds.width - 320)   // 左侧网格至少留 320pt
            let newW = min(560, max(180, self.previewWidth - dx))
            guard abs(newW - self.previewWidth) > 0.5 else { return }
            self.previewWidth = min(newW, maxW)
            UserDefaults.standard.set(self.previewWidth, forKey: "folderPreviewWidth")
            self.needsLayout = true
        }
        addSubview(previewPane)

        // 大图完整显示模式：整图等比放进可视区居中，无滚动条、无拖拽平移。
        previewScroll.drawsBackground = false
        previewScroll.borderType = .noBorder
        previewScroll.hasVerticalScroller = false
        previewScroll.hasHorizontalScroller = false
        previewScroll.autohidesScrollers = true
        // 禁用滚动视图的弹性/隐式动画，避免切换时出现虚影残影。
        previewScroll.scrollsDynamically = false
        previewScroll.documentView = previewImage
        previewPane.addSubview(previewScroll)
        // 文本渲染预览（markdown/文档）：白色纸面卡片，还原原始白底黑字观感，不透玻璃。
        previewTextScroll.drawsBackground = true
        previewTextScroll.backgroundColor = .white
        previewTextScroll.borderType = .noBorder
        previewTextScroll.hasVerticalScroller = true
        previewTextScroll.autohidesScrollers = true
        previewTextScroll.wantsLayer = true
        previewTextScroll.layer?.cornerRadius = 10
        previewTextScroll.layer?.masksToBounds = true
        previewTextView.isVerticallyResizable = true
        previewTextView.isHorizontallyResizable = false
        previewTextView.autoresizingMask = [.width]
        previewTextView.drawsBackground = true
        previewTextView.backgroundColor = .white
        previewTextView.textContainerInset = NSSize(width: 14, height: 12)
        previewTextView.textContainer?.widthTracksTextView = true
        previewTextScroll.documentView = previewTextView
        previewTextScroll.isHidden = true
        previewPane.addSubview(previewTextScroll)
        if let ql = previewQLView {
            ql.isHidden = true
            previewPane.addSubview(ql)
        }
        previewName.font = .systemFont(ofSize: 12, weight: .medium)
        previewName.font = .systemFont(ofSize: 13, weight: .semibold)
        previewName.textColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        previewName.lineBreakMode = .byTruncatingMiddle
        previewPane.addSubview(previewName)
        previewMeta.font = .systemFont(ofSize: 10)
        previewMeta.textColor = NSColor(calibratedWhite: 0.08, alpha: 0.5)
        previewMeta.lineBreakMode = .byTruncatingMiddle
        previewPane.addSubview(previewMeta)
        addSubview(previewPane)
        previewPane.isHidden = true

        // 标题栏滑块：网格图标大小。
        gridScaleSlider.target = self
        gridScaleSlider.action = #selector(gridScaleChanged(_:))
        addSubview(gridScaleSlider)
        gridScalePercent.font = .systemFont(ofSize: 10)
        gridScalePercent.textColor = NSColor(calibratedWhite: 0.08, alpha: 0.5)
        gridScalePercent.alignment = .right
        gridScalePercent.stringValue = "\(Int((FolderPreviewGrid.iconScale * 100).rounded()))%"
        addSubview(gridScalePercent)

        addSubview(resizeHandle)
        // 分隔条拖拽热区必须盖在 previewPane 之上（后加的在上面）。
        addSubview(dividerGrab, positioned: .above, relativeTo: nil)
        // 外描边盖在最上层（不挡点击），与托盘窗口观感一致。
        let outline = PreviewOutlineView()
        addSubview(outline, positioned: .above, relativeTo: nil)
        outlineStored = outline

        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                               object: nil, queue: .main) { [weak self] note in
            guard let panel = self?.window as? FolderPreviewPanel, note.object as? NSWindow == panel else { return }
            panel.hideAndRelease()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        effect.frame = bounds
        outlineStored?.frame = bounds
        let titleMaxW = bounds.width - 320
        titleLabel.frame = NSRect(x: 18, y: 14, width: max(120, min(280, titleMaxW)), height: 20)
        pathLabel.frame = NSRect(x: 18, y: 34, width: max(120, bounds.width - 360), height: 14)
        // 标题栏右侧：网格图标大小滑块 + 百分比。
        gridScaleSlider.frame = NSRect(x: bounds.width - 268, y: 15, width: 196, height: 18)
        gridScalePercent.frame = NSRect(x: bounds.width - 62, y: 17, width: 44, height: 14)
        resizeHandle.frame = NSRect(x: bounds.width - 34, y: bounds.height - 34, width: 34, height: 34)

        let hasPreview = !previewPane.isHidden
        let contentWidth = bounds.width - (hasPreview ? previewWidth : 0)
        scroll.frame = NSRect(x: 0, y: 54, width: contentWidth, height: bounds.height - 54)
        grid.layoutGrid(width: scroll.contentSize.width)
        if hasPreview {
            previewDivider.frame = NSRect(x: contentWidth - 0.5, y: 54, width: 0.5, height: bounds.height - 54)
            dividerGrab.frame = NSRect(x: contentWidth - 5, y: 54, width: 10, height: bounds.height - 54)
            previewPane.frame = NSRect(x: contentWidth, y: 54, width: previewWidth, height: bounds.height - 54)
            // 子视图 frame 相对 previewPane 本身（宽 previewWidth）。
            let pad: CGFloat = 14
            let metaH: CGFloat = 14
            let nameH: CGFloat = 17
            let paneH = bounds.height - 54
            let textBlock = metaH + nameH + 6 + pad
            // 大图/文本渲染放滚动容器（上部），文件名+大小/日期贴底部。
            let contentFrame = NSRect(x: 0, y: textBlock, width: previewWidth, height: paneH - textBlock - pad)
            previewScroll.frame = contentFrame
            // 白色纸面卡片四边留 8pt 玻璃边。
            previewTextScroll.frame = contentFrame.insetBy(dx: 8, dy: 6)
            previewQLView?.frame = contentFrame
            // 底部文字块：meta 贴底（pad~pad+14），name 在其上方（间隔 4pt，不重叠）。
            previewName.frame = NSRect(x: pad, y: pad + metaH + 4,
                                       width: previewWidth - pad * 2, height: nameH)
            previewMeta.frame = NSRect(x: pad, y: pad,
                                       width: previewWidth - pad * 2, height: metaH)
            relayoutPreviewImage()
        }
    }

    /// 图片预览完整显示：文档视图等于可视区，`.resizeAspect` 把整张图等比缩放后
    /// 居中放进右栏——不裁切、不滚动、一眼看全图。窗口/右栏缩放时同步等比变化。
    private func relayoutPreviewImage() {
        let avail = previewScroll.contentSize
        guard avail.width > 10, avail.height > 10 else { return }
        previewImage.frame = NSRect(origin: .zero, size: avail)
    }

    /// 网格图标大小滑块。
    @objc private func gridScaleChanged(_ sender: NSSlider) {
        let scale = CGFloat(sender.doubleValue)
        FolderPreviewGrid.iconScale = scale
        gridScalePercent.stringValue = "\(Int((scale * 100).rounded()))%"
        grid.applyScaleChange()
    }

    func load(folderURL url: URL) {
        folderURL = url
        titleLabel.stringValue = url.lastPathComponent
        pathLabel.stringValue = url.deletingLastPathComponent().path
        updatePreview(for: nil)
        grid.load(folderURL: url)
        needsLayout = true
    }

    /// 统一的预览资源释放入口：面板隐藏/关闭前调用，作废在途加载回调并释放图像文本。
    func releasePreviewResources() {
        updatePreview(for: nil)
    }

    /// 网格选中变化时刷新右侧预览。三条路：
    /// 图片 → ImageIO 降采样读原图（清晰）；markdown → 自渲染富文本；
    /// 其它文档 → 内嵌 Quick Look 原生视图（原始排版高清渲染，非缩略图）。
    fileprivate func updatePreview(for item: FolderPreviewGrid.Item?) {
        func hideAll() {
            previewScroll.isHidden = true
            previewTextScroll.isHidden = true
            previewQLView?.isHidden = true
            previewQLView?.previewItem = nil   // 释放上一个文档
            qlOverlayTimer?.invalidate()
            qlOverlayTimer = nil
        }
        guard let item else {
            if previewPane.isHidden { return }
            hideAll()
            // 关闭预览：作废在途加载回调并释放图像/文本，别让面板隐藏后仍占着大图内存。
            previewToken += 1
            previewImage.image = nil
            previewTextView.textStorage?.setAttributedString(NSAttributedString(string: ""))
            previewPane.isHidden = true
            needsLayout = true
            return
        }
        previewPane.isHidden = false
        previewName.stringValue = item.name
        previewMeta.stringValue = Self.metaText(url: item.url)
        needsLayout = true
        previewToken += 1
        let token = previewToken

        let ext = item.url.pathExtension.lowercased()
        if !item.isDirectory, ["md", "markdown", "mdown", "mkd"].contains(ext) {
            // markdown：渲染成富文本显示。
            hideAll()
            previewTextScroll.isHidden = false
            previewTextView.textStorage?.setAttributedString(
                NSAttributedString(string: "渲染中…", attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                // 只在后台读文件，所有 AppKit 属性化在主线程做。
                let raw = try? String(contentsOf: item.url, encoding: .utf8)
                let baseURL = item.url.deletingLastPathComponent()
                DispatchQueue.main.async {
                    guard let self, self.previewToken == token else { return }
                    if let raw {
                        let attr = Self.renderMarkdown(content: raw, baseURL: baseURL, contentWidth: self.previewWidth)
                        self.previewTextView.textStorage?.setAttributedString(attr)
                        self.resizePreviewTextView()
                    } else {
                        self.previewTextView.textStorage?.setAttributedString(
                            NSAttributedString(string: "无法读取文件", attributes: [
                                .font: NSFont.systemFont(ofSize: 12),
                                .foregroundColor: NSColor.secondaryLabelColor,
                            ]))
                    }
                    // 回到顶部。
                    self.previewTextScroll.contentView.bounds.origin = .zero
                    self.previewTextView.scrollToVisible(self.previewTextView.bounds)
                }
            }
            return
        }

        let isImage = UTType(filenameExtension: ext)?.conforms(to: .image) ?? false
        if isImage {
            hideAll()
            previewScroll.isHidden = false
            // 首次打开（还没有旧图）才用系统图标占位；切换图片时保留上一张画面，
            // 避免先蹦出小图标再换原图的突闪。
            if previewImage.image == nil {
                previewImage.image = NSWorkspace.shared.icon(forFile: item.url.path)
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                // 后台只解码 CGImage / 读 Data；NSImage 在主线程包装。
                let cg = Self.loadDisplayCGImage(url: item.url)
                let fallbackData = cg == nil ? (try? Data(contentsOf: item.url)) : nil
                DispatchQueue.main.async {
                    guard let self, self.previewToken == token else { return }
                    let image: NSImage?
                    if let cg {
                        image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    } else if let fallbackData {
                        image = NSImage(data: fallbackData)
                    } else {
                        image = nil
                    }
                    if let image {
                        self.previewImage.image = image
                        self.needsLayout = true
                        self.relayoutPreviewImage()
                    } else {
                        // 加载失败：清掉旧图/占位图标，明确提示——
                        // 否则会一直显示上一张的画面配这个新文件名，误导且占内存。
                        self.previewImage.image = nil
                        hideAll()
                        self.previewTextScroll.isHidden = false
                        self.previewTextView.textStorage?.setAttributedString(
                            NSAttributedString(string: "无法显示此图片（文件可能已损坏或格式不受支持）", attributes: [
                                .font: NSFont.systemFont(ofSize: 13),
                                .foregroundColor: NSColor.secondaryLabelColor
                            ]))
                        self.needsLayout = true
                    }
                }
            }
        } else if !item.isDirectory, let t = UTType(filenameExtension: ext),
                  t.conforms(to: .pdf) || t.conforms(to: .movie) || t.conforms(to: .video) || t.conforms(to: .audio) {
            // PDF/视频/音频：内嵌 Quick Look。PDF 连续排版滚轮可直接滚，视频/音频可播放。
            hideAll()
            previewQLView?.isHidden = false
            previewQLView?.previewItem = item.url as NSURL
            if t.conforms(to: .pdf) {
                // QL 会给多页 PDF 弹 ‹ › 翻页玻璃圆钮（QLOverlayGlassBackground），
                // 与滚轮滚动形态冲突，出现即隐藏（定时兜底，防它延迟出现/复显）。
                qlOverlayTimer?.invalidate()
                let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
                    self?.hideQLOverlayButtons()
                }
                RunLoop.main.add(timer, forMode: .common)
                qlOverlayTimer = timer
                hideQLOverlayButtons()
            }
        } else if !item.isDirectory, Self.richDocExts.contains(ext) {
            // Word/HTML/文本等：系统 NSAttributedString 导入（可滚动、保留标题/加粗/内嵌图片），
            // 比 QL 内嵌视图可靠——后者对 docx 是「翻页切换」形态且滚轮滚不动。
            hideAll()
            previewTextScroll.isHidden = false
            previewTextView.textStorage?.setAttributedString(
                NSAttributedString(string: "加载中…", attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                // 后台读 Data，NSAttributedString 在主线程构造。
                let data = try? Data(contentsOf: item.url)
                DispatchQueue.main.async {
                    guard let self, self.previewToken == token else { return }
                    var result: NSAttributedString?
                    if let data,
                       let loaded = try? NSAttributedString(data: data, options: [:], documentAttributes: nil),
                       loaded.length > 0 {
                        // 原样保留（白纸面上显示原始排版与配色，不重上色）。
                        result = loaded
                    }
                    if let result {
                        self.previewTextView.textStorage?.setAttributedString(result)
                        self.resizePreviewTextView()
                        self.previewTextScroll.contentView.bounds.origin = .zero
                    } else {
                        // 读不出内容：右栏只留文件名+大小/日期。
                        self.previewTextScroll.isHidden = true
                    }
                }
            }
        } else {
            hideAll()
        }
    }

    /// 非可编辑 NSTextView 不会自动长高：排版后按 usedRect 显式撑高 documentView，否则超出部分被裁掉且滚不动。
    private func resizePreviewTextView() {
        guard let layoutManager = previewTextView.layoutManager,
              let textContainer = previewTextView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let inset = previewTextView.textContainerInset
        let width = max(50, previewTextScroll.contentSize.width)
        previewTextView.frame = NSRect(x: 0, y: 0, width: width,
                                       height: used.height + inset.height * 2 + 8)
    }

    /// 隐藏 Quick Look 的 ‹ › 翻页玻璃圆钮（递归按类名匹配）。
    private func hideQLOverlayButtons() {
        guard let ql = previewQLView, !ql.isHidden else {
            qlOverlayTimer?.invalidate()
            qlOverlayTimer = nil
            return
        }
        func walk(_ v: NSView) {
            for sub in v.subviews {
                if String(describing: type(of: sub)) == "QLOverlayGlassBackground" {
                    if !sub.isHidden { sub.isHidden = true }
                } else {
                    walk(sub)
                }
            }
        }
        walk(ql)
    }

    /// 能用系统 NSAttributedString 导入的文档扩展名（滚动查看，失败则只显示文件名栏）。
    private static let richDocExts: Set<String> = ["doc", "docx", "ppt", "pptx", "odt", "rtf", "rtfd",
                                                   "html", "htm", "pages", "numbers", "key",
                                                   "txt", "log", "csv", "json", "xml", "webarchive"]

    /// 图片文件：读原图并降采样到适合预览的分辨率（清晰且省内存）；非图片返回 nil。
    /// 注意：只返回 CGImage，调用方必须在主线程再包装成 NSImage。
    private static func loadDisplayCGImage(url: URL) -> CGImage? {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else {
            return nil
        }
        let maxPixel: CGFloat = 4096   // 与右侧预览最大显示边长保持一致，保证“原图”预览不额外降采样。
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCache: false,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            return nil
        }
        return cg
    }

    /// markdown → 富文本（自研渲染器）。
    /// 系统的 NSAttributedString(markdown:) 不产出块级样式也不产字体（实测），只能自己来：
    /// 标题六级字号 / 围栏代码块 / 表格(NSTextTable) / 列表 / 引用 / 分割线 / 内嵌图片（data:URI 解码），
    /// 行内样式（**粗**、*斜*、`码`、~~删~~、[链接](url)）由 inlineRender 递归处理，支持跨行。
    /// 把 markdown 文本渲染成 NSAttributedString。调用方必须保证在主线程执行
    ///（因为内部创建 NSFont/NSColor/NSImage/NSTextAttachment 等 AppKit 对象）。
    private static func renderMarkdown(content: String, baseURL: URL, contentWidth: CGFloat) -> NSAttributedString {
        var raw = content
        // 内嵌图片：<img src="data:image/...;base64,...">（base64 常跨数行超长）解码成 NSImage，
        // 原位置替换为占位标记行，主循环里渲染成真正的行内图片（否则整段变成乱码文本）。
        var embeddedImages: [NSImage] = []
        guard let imgPattern = try? NSRegularExpression(
            pattern: "<img\\s[^>]*?src\\s*=\\s*[\"']data:image/[^;\"']+;base64,([A-Za-z0-9+/=\\s]+?)\\s*[\"']") else {
            return NSAttributedString(string: raw)
        }
        let ns = NSMutableString(string: raw)
        while let m = imgPattern.firstMatch(in: ns as String, range: NSRange(location: 0, length: ns.length)) {
            let full = ns as String
            guard let r = Range(m.range(at: 1), in: full) else { break }
            let b64 = full[r].replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
            if let data = Data(base64Encoded: b64), let img = NSImage(data: data) {
                embeddedImages.append(img)
                ns.replaceCharacters(in: m.range, with: "\n@@IMG:\(embeddedImages.count - 1)@@\n")
            } else {
                ns.replaceCharacters(in: m.range, with: "")
            }
        }
        raw = ns as String
        // 剥掉剩余内嵌 HTML 标签：<a href="data:...巨型base64..."> 这类会整段变成乱码文本。
        // <a ...> 开标签（href 可能跨行）直接删，保留链接文字；<br> 转换行；其余标签删除。
        for (pattern, tmpl) in [("<a\\s[\\s\\S]*?>", ""), ("</a\\s*>", ""),
                                ("<br\\s*/?>", "\n"), ("<[^<>\\n]{0,300}>", "")] {
            raw = raw.replacingOccurrences(of: pattern, with: tmpl, options: .regularExpression)
        }
        // 白色纸面卡片：文字用深色（labelColor 系），还原文档原貌。
        let white = NSColor.labelColor
        let gray = NSColor.secondaryLabelColor
        let out = NSMutableAttributedString()
        let nl = NSAttributedString(string: "\n")
        let headingSizes: [CGFloat] = [24, 20, 17, 15, 14, 13]
        let lines = raw.components(separatedBy: "\n")
        var i = 0

        func looksLikeTableSeparator(_ s: String) -> Bool {
            let t = s.trimmingCharacters(in: .whitespaces)
            guard t.contains("-") else { return false }
            return t.range(of: "^\\|?[\\s:\\-|]+\\|?$", options: .regularExpression) != nil
        }
        func splitTableRow(_ s: String) -> [String] {
            var t = s.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("|") { t.removeFirst() }
            if t.hasSuffix("|") { t.removeLast() }
            return t.components(separatedBy: "|").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 内嵌图片占位标记（<img src="data:..."> 解码后的替换行）
            if trimmed.hasPrefix("@@IMG:"), trimmed.hasSuffix("@@"),
               let idx = Int(trimmed.dropFirst(6).dropLast(2)), idx >= 0, idx < embeddedImages.count {
                out.append(Self.imageAttachment(embeddedImages[idx], maxWidth: max(120, contentWidth - 28)))
                out.append(NSAttributedString(string: "\n\n"))
                i += 1
                continue
            }

            // markdown 图片 ![说明](data:image/... 或 相对路径)
            if trimmed.hasPrefix("!["),
               let inner = try? NSRegularExpression(pattern: "^!\\[[^\\]]*\\]\\(([^)]+)\\)$"),
               let mm = inner.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               let r = Range(mm.range(at: 1), in: trimmed) {
                let src2 = String(trimmed[r])
                var img: NSImage?
                if src2.hasPrefix("data:image"),
                   let comma = src2.range(of: "base64,") {
                    let b64 = String(src2[comma.upperBound...]).replacingOccurrences(of: "\\s", with: "")
                    if let data = Data(base64Encoded: b64) { img = NSImage(data: data) }
                } else {
                    let p = (src2.removingPercentEncoding ?? src2)
                    if p.hasPrefix("/") { img = NSImage(contentsOfFile: p) }
                    else { img = NSImage(contentsOf: baseURL.appendingPathComponent(p)) }
                }
                if let img {
                    out.append(Self.imageAttachment(img, maxWidth: max(120, contentWidth - 28)))
                    out.append(NSAttributedString(string: "\n\n"))
                    i += 1
                    continue
                }
            }

            // 围栏代码块 ```
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                i += 1
                var codeLines: [String] = []
                while i < lines.count,
                      !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```"),
                      !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("~~~") {
                    codeLines.append(lines[i])
                    i += 1
                }
                i += 1   // 跳过收尾围栏
                if !codeLines.isEmpty {
                    out.append(NSAttributedString(string: codeLines.joined(separator: "\n") + "\n\n", attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                        .foregroundColor: gray,
                        .backgroundColor: NSColor.black.withAlphaComponent(0.05),
                    ]))
                }
                continue
            }

            // 分割线
            if ["---", "***", "___"].contains(trimmed) {
                out.append(NSAttributedString(string: "———————————————\n\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: NSColor.separatorColor,
                ]))
                i += 1
                continue
            }

            // 表格：本行以 | 开头 + 下一行是分隔行
            if trimmed.hasPrefix("|"), i + 1 < lines.count, looksLikeTableSeparator(lines[i + 1]) {
                let header = splitTableRow(trimmed)
                i += 2
                var rows: [[String]] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(splitTableRow(lines[i]))
                    i += 1
                }
                out.append(Self.buildTable(header: header, rows: rows))
                out.append(nl)
                continue
            }

            // 引用 >
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    quoteLines.append(t.hasPrefix(">") ? String(t.dropFirst()).trimmingCharacters(in: .whitespaces) : t)
                    i += 1
                }
                let body = inlineRender(quoteLines.joined(separator: "\n"), base: .systemFont(ofSize: 13), baseURL: baseURL)
                let q = NSMutableAttributedString(string: "▎ ", attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ])
                q.append(body)
                q.append(NSAttributedString(string: "\n\n"))
                q.addAttribute(.foregroundColor, value: gray, range: NSRange(location: 0, length: q.length))
                out.append(q)
                continue
            }

            // 空行
            if trimmed.isEmpty {
                out.append(nl)
                i += 1
                continue
            }

            // 标题
            if trimmed.hasPrefix("#"), trimmed.prefix(while: { $0 == "#" }).count <= 6,
               trimmed.dropFirst(trimmed.prefix(while: { $0 == "#" }).count).hasPrefix(" ") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                let content = String(trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces))
                let font = NSFont.systemFont(ofSize: headingSizes[level - 1], weight: .semibold)
                if level <= 2 { out.append(nl) }
                out.append(inlineRender(content, base: font, baseURL: baseURL))
                out.append(NSAttributedString(string: "\n\n"))
                i += 1
                continue
            }

            // 列表项（可带缩进）
            if let listMatch = Self.listPrefix(of: trimmed) {
                let indent = line.count - line.trimmingCharacters(in: .whitespaces).count
                let tabs = String(repeating: "    ", count: indent / 2)
                out.append(NSAttributedString(string: tabs + listMatch.bullet + " ", attributes: [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: white,
                ]))
                out.append(inlineRender(listMatch.rest, base: .systemFont(ofSize: 13), baseURL: baseURL))
                out.append(nl)
                i += 1
                continue
            }

            // 普通段落：合并连续行（行内样式可跨行），软换行保留。
            var paraLines: [String] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("#") || t.hasPrefix("```") || t.hasPrefix("~~~")
                    || t.hasPrefix("|") || t.hasPrefix(">") || t.hasPrefix("@@IMG:")
                    || t.hasPrefix("![") || ["---", "***", "___"].contains(t)
                    || Self.listPrefix(of: t) != nil { break }
                paraLines.append(lines[i])
                i += 1
            }
            out.append(inlineRender(paraLines.joined(separator: "\n"), base: .systemFont(ofSize: 13), baseURL: baseURL))
            out.append(nl)
        }
        out.addAttribute(.foregroundColor, value: white, range: NSRange(location: 0, length: out.length))
        // 链接最后统一上色加下划线（避免被整体上色覆盖）。
        out.enumerateAttribute(.link, in: NSRange(location: 0, length: out.length)) { value, r, _ in
            guard value != nil else { return }
            out.addAttribute(.foregroundColor, value: NSColor.linkColor, range: r)
            out.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r)
        }
        return out
    }

    /// NSImage → 行内图片附件（等比缩到预览栏宽度内）。
    private static func imageAttachment(_ img: NSImage, maxWidth: CGFloat) -> NSAttributedString {
        let attach = NSTextAttachment()
        attach.image = img
        let w = min(max(1, img.size.width), maxWidth)
        let h = img.size.height * (w / max(1, img.size.width))
        attach.bounds = NSRect(x: 0, y: 0, width: w, height: h)
        return NSAttributedString(attachment: attach)
    }

    /// 识别列表前缀：- / * / + / 1. / 1) →（保持原序号，符号统一转 •；有序列表保留原样）。
    private static func listPrefix(of s: String) -> (bullet: String, rest: String)? {
        if s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ") {
            return ("•", String(s.dropFirst(2)))
        }
        if let m = s.range(of: "^\\d{1,3}[.)][ \\t]", options: .regularExpression) {
            return (String(s[m]), String(s[m.upperBound...]))
        }
        return nil
    }

    /// 行内样式渲染：`code`、**粗**、*斜*、~~删~~、[文字](链接)，递归支持嵌套与跨行。
    private static func inlineRender(_ text: String, base: NSFont, baseURL: URL) -> NSAttributedString {
        var out = NSMutableAttributedString()
        let plain: [NSAttributedString.Key: Any] = [.font: base]
        var range = NSRange(location: 0, length: text.utf16.count)
        // 各语法规则：正则 + 处理器。
        let codeFont = NSFont.monospacedSystemFont(ofSize: max(11, base.pointSize - 1), weight: .regular)
        let rules: [(NSRegularExpression, (NSString, NSTextCheckingResult, inout NSMutableAttributedString) -> Void)] = [
            (try! NSRegularExpression(pattern: "`([^`\\n]+)`"), { s, m, buf in
                buf.append(NSAttributedString(string: s.substring(with: NSRange(location: m.range(at: 1).location, length: m.range(at: 1).length)), attributes: [
                    .font: codeFont,
                    .backgroundColor: NSColor.black.withAlphaComponent(0.06),
                ]))
            }),
            (try! NSRegularExpression(pattern: "\\*\\*([\\s\\S]+?)\\*\\*"), { s, m, buf in
                let inner = s.substring(with: NSRange(location: m.range(at: 1).location, length: m.range(at: 1).length))
                buf.append(inlineRender(inner, base: NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask), baseURL: baseURL))
            }),
            (try! NSRegularExpression(pattern: "(?<!\\*)\\*([^*\\n]+)\\*(?!\\*)"), { s, m, buf in
                let inner = s.substring(with: NSRange(location: m.range(at: 1).location, length: m.range(at: 1).length))
                buf.append(inlineRender(inner, base: NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask), baseURL: baseURL))
            }),
            (try! NSRegularExpression(pattern: "~~([\\s\\S]+?)~~"), { s, m, buf in
                let inner = s.substring(with: NSRange(location: m.range(at: 1).location, length: m.range(at: 1).length))
                let part = NSMutableAttributedString(attributedString: inlineRender(inner, base: base, baseURL: baseURL))
                part.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: part.length))
                buf.append(part)
            }),
            (try! NSRegularExpression(pattern: "\\[([^\\]\\n]+)\\]\\(([^)\\n]+)\\)"), { s, m, buf in
                let label = s.substring(with: NSRange(location: m.range(at: 1).location, length: m.range(at: 1).length))
                var target = s.substring(with: NSRange(location: m.range(at: 2).location, length: m.range(at: 2).length))
                let linkURL: URL
                if let u = URL(string: target) { linkURL = u }
                else { linkURL = URL(fileURLWithPath: target, relativeTo: baseURL) }
                if target.hasPrefix("#") { target = "" }
                let attr: [NSAttributedString.Key: Any] = [.link: target.isEmpty ? linkURL : linkURL, .font: base]
                buf.append(NSAttributedString(string: label, attributes: attr))
            }),
        ]

        while range.length > 0 {
            // 找最早命中的规则。
            var best: (NSTextCheckingResult, Int)? = nil
            for (idx, rule) in rules.enumerated() {
                if let m = rule.0.firstMatch(in: text, options: [], range: range) {
                    if best == nil || m.range.location < best!.0.range.location { best = (m, idx) }
                }
            }
            guard let (m, idx) = best else {
                out.append(NSAttributedString(string: (text as NSString).substring(with: range), attributes: plain))
                break
            }
            if m.range.location > range.location {
                let pre = NSRange(location: range.location, length: m.range.location - range.location)
                out.append(NSAttributedString(string: (text as NSString).substring(with: pre), attributes: plain))
            }
            rules[idx].1(text as NSString, m, &out)
            range = NSRange(location: m.range.location + m.range.length,
                            length: range.length - (m.range.location - range.location) - m.range.length)
        }
        return out
    }

    /// markdown 表格 → 等宽字体对齐的文本表格（列宽按显示宽度计算，CJK 算 2 格，底色区分表头）。
    /// NSTextTableBlock 在当前 SDK 无法通过属性键被排版引擎识别（实测），只能这么对齐。
    private static func buildTable(header: [String], rows: [[String]]) -> NSAttributedString {
        let mono = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        var all = [header] + rows
        let cols = all.map(\.count).max() ?? 1
        for idx in all.indices {
            while all[idx].count < cols { all[idx].append("") }
        }
        // 每列最大显示宽度（上限 28，超长截断）。
        var colWidths = [Int](repeating: 0, count: cols)
        for row in all {
            for (c, cell) in row.enumerated() {
                colWidths[c] = min(28, max(colWidths[c], displayWidth(cell)))
            }
        }
        func padCell(_ s: String, _ width: Int) -> String {
            var out = s
            while displayWidth(out) < width { out += " " }
            return out
        }
        func emitRow(_ cells: [String], headerBg: Bool) -> NSAttributedString {
            var line = ""
            for (c, cell) in cells.enumerated() {
                if c > 0 { line += "   " }
                line += padCell(cell, colWidths[c])
            }
            return NSAttributedString(string: line, attributes: [
                .font: mono,
                .backgroundColor: headerBg ? NSColor.black.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.04),
            ])
        }
        let out = NSMutableAttributedString()
        out.append(emitRow(header, headerBg: true))
        out.append(NSAttributedString(string: "\n", attributes: [.font: mono]))
        for row in rows {
            out.append(emitRow(row, headerBg: false))
            out.append(NSAttributedString(string: "\n", attributes: [.font: mono]))
        }
        out.append(NSAttributedString(string: "\n"))
        return out
    }

    /// 字符串显示宽度：CJK/全角字符算 2，其它算 1。
    private static func displayWidth(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { w, scalar in
            let v = scalar.value
            let wide = (v >= 0x1100 && v <= 0x115F) || (v >= 0x2E80 && v <= 0xA4CF)
                || (v >= 0xAC00 && v <= 0xD7A3) || (v >= 0xF900 && v <= 0xFAFF)
                || (v >= 0xFE30 && v <= 0xFE4F) || (v >= 0xFF00 && v <= 0xFF60)
                || (v >= 0xFFE0 && v <= 0xFFE6) || (v >= 0x20000 && v <= 0x3FFFD)
            return w + (wide ? 2 : 1)
        }
    }

    private static func metaText(url: URL) -> String {
        var parts: [String] = []
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64 {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            parts.append(formatter.string(fromByteCount: size))
        }
        if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            parts.append(DateFormatter.localizedString(from: modified, dateStyle: .short, timeStyle: .short))
        }
        return parts.joined(separator: " · ")
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 53 {
            // 空格/esc：根目录时关闭，子目录时先返回上一级。
            if event.keyCode == 53, let parent = grid.currentURL?.deletingLastPathComponent(),
               grid.currentURL != folderURL {
                load(folderURL: parent)
            } else if let panel = window as? FolderPreviewPanel {
                panel.hideAndRelease()
            } else {
                window?.orderOut(nil)
            }
        } else if event.keyCode == 125 || event.keyCode == 123 || event.keyCode == 124 || event.keyCode == 126 {
            grid.moveSelection(keyCode: event.keyCode)
        } else if event.keyCode == 36 {
            grid.openSelected()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// 网格内容：图标 64pt + 名称，点击选中，双击进文件夹/打开文件。
private final class FolderPreviewGrid: NSView {
    struct Item {
        let url: URL
        let name: String
        let isDirectory: Bool
    }

    // 网格图标缩放（面板标题栏滑块调节），0.7x ~ 2.0x，重启保留。
    static var iconScale: CGFloat {
        get { UserDefaults.standard.object(forKey: "folderGridScale") as? CGFloat ?? 1.0 }
        set { UserDefaults.standard.set(newValue, forKey: "folderGridScale") }
    }
    static var cellW: CGFloat { 104 * iconScale }
    static var cellH: CGFloat { 118 * iconScale }

    weak var owner: FolderPreviewRoot?
    private(set) var currentURL: URL?
    private var items: [Item] = []
    private var cells: [FolderPreviewCell] = []
    private var selectedIndex: Int?
    private var needsRelayout = false

    override var isFlipped: Bool { true }

    func load(folderURL url: URL) {
        currentURL = url
        cells.forEach { $0.removeFromSuperview() }
        cells = []
        selectedIndex = nil
        let raw = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        items = raw
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .map { item in
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return Item(url: item, name: item.lastPathComponent, isDirectory: isDir)
            }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        for (index, item) in items.enumerated() {
            let cell = FolderPreviewCell(item: item, index: index)
            cell.target = self
            addSubview(cell)
            cells.append(cell)
        }
        needsRelayout = true
        needsLayout = true
        // 打开/进入文件夹时自动选中第一个文件：右侧立刻有大图，方向键直接接着翻。
        if let firstIndex = items.firstIndex(where: { !$0.isDirectory }) {
            setSelected(firstIndex)
        } else {
            setSelected(nil)
        }
    }

    override func layout() {
        super.layout()
        if needsRelayout {
            needsRelayout = false
            layoutGrid(width: max(320, superview?.bounds.width ?? 880))
        }
    }

    func layoutGrid(width: CGFloat) {
        let cellW = Self.cellW, cellH = Self.cellH
        let padding: CGFloat = 16
        let columns = max(1, Int((width - padding * 2 + 8) / cellW))
        for (index, cell) in cells.enumerated() {
            let row = index / columns, col = index % columns
            cell.frame = NSRect(x: padding + CGFloat(col) * cellW,
                                y: padding + CGFloat(row) * cellH,
                                width: cellW, height: cellH)
        }
        let rows = (cells.count + columns - 1) / columns
        let contentHeight = padding * 2 + CGFloat(max(1, rows)) * cellH
        let contentWidth = padding * 2 + CGFloat(columns) * cellW
        if frame.size != NSSize(width: contentWidth, height: contentHeight) {
            frame = NSRect(origin: .zero, size: NSSize(width: contentWidth, height: contentHeight))
        }
    }

    /// 图标缩放变化后：格子尺寸/字号重排。
    func applyScaleChange() {
        for cell in cells { cell.applyScale() }
        needsRelayout = true
        needsLayout = true
    }

    func setSelected(_ index: Int?) {        selectedIndex = index
        for (i, cell) in cells.enumerated() { cell.isSelected = (i == index) }
        // 选中变化 → 右侧大图预览跟着切（文件夹项只显示大图标）。
        if let index, index < items.count {
            owner?.updatePreview(for: items[index])
        } else {
            owner?.updatePreview(for: nil)
        }
    }

    func moveSelection(keyCode: UInt16) {
        guard !cells.isEmpty else { return }
        let columns = max(1, cells.first.map { _ in
            let width = max(320, superview?.bounds.width ?? 880)
            return Int((width - 24) / Self.cellW)
        } ?? 1)
        var index = selectedIndex ?? 0
        switch keyCode {
        case 123: index -= 1          // ←
        case 124: index += 1          // →
        case 126: index -= columns    // ↑
        case 125: index += columns    // ↓
        default: return
        }
        index = max(0, min(cells.count - 1, index))
        setSelected(index)
        if index < cells.count { cells[index].scrollToVisible() }
    }

    func openSelected() {
        guard let index = selectedIndex, index < items.count else { return }
        open(item: items[index])
    }

    private func open(item: Item) {
        if item.isDirectory {
            owner?.load(folderURL: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    fileprivate func handleDoubleClick(_ cell: FolderPreviewCell) {
        guard cell.index < items.count else { return }
        open(item: items[cell.index])
    }

    fileprivate func item(at index: Int) -> Item? {
        guard index >= 0, index < items.count else { return nil }
        return items[index]
    }

    fileprivate func reloadCurrentFolder() {
        guard let url = currentURL else { return }
        load(folderURL: url)
    }
}

private final class FolderPreviewCell: NSView, NSDraggingSource {
    let index: Int
    var isSelected = false { didSet { refresh() } }
    weak var target: FolderPreviewGrid?
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private var dragStartPoint: NSPoint?
    private var isDraggingSession = false

    init(item: FolderPreviewGrid.Item, index: Int) {
        self.index = index
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSWorkspace.shared.icon(forFile: item.url.path)
        // NSImageView 默认注册图片拖放，会吞掉 mouseDragged；清空让它只做展示。
        iconView.registerForDraggedTypes([])
        addSubview(iconView)

        nameLabel.font = .systemFont(ofSize: max(8, min(16, 11 * FolderPreviewGrid.iconScale)))
        nameLabel.alignment = .center
        nameLabel.maximumNumberOfLines = 2
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.stringValue = item.name
        nameLabel.textColor = NSColor(calibratedWhite: 0.08, alpha: 0.88)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            // 图标占格子宽度 ~58%：缩放滑块改格子大小时自动跟随。
            iconView.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.577),
            iconView.heightAnchor.constraint(equalTo: iconView.widthAnchor),
            nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
        ])
        loadThumbnail(url: item.url)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func refresh() {
        layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.30).cgColor
            : NSColor.clear.cgColor
        layer?.borderWidth = isSelected ? 1.5 : 0
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
    }

    func applyScale() {
        nameLabel.font = .systemFont(ofSize: max(8, min(16, 11 * FolderPreviewGrid.iconScale)))
    }

    func scrollToVisible() {
        superview?.scrollToVisible(frame.insetBy(dx: 0, dy: -20))
    }

    override func mouseDown(with event: NSEvent) {
        dragStartPoint = convert(event.locationInWindow, from: nil)
        isDraggingSession = false
        if event.clickCount >= 2 {
            target?.handleDoubleClick(self)
        } else {
            target?.setSelected(index)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartPoint, !isDraggingSession,
              let item = target?.item(at: index) else { return }
        let location = convert(event.locationInWindow, from: nil)
        let dist = hypot(location.x - start.x, location.y - start.y)
        guard dist > 4 else { return }
        isDraggingSession = true

        let draggingItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
        let sourceImage = iconView.image ?? NSWorkspace.shared.icon(forFile: item.url.path)
        // 拖拽镜像保持照片原始宽高比等比缩小（最大边 80pt），不做正方形硬裁，
        // 竖图镜像就是竖长方形，跟格子里的等比缩略图观感一致。
        let srcSize = sourceImage.size
        let maxSide: CGFloat = 80
        let w: CGFloat
        let h: CGFloat
        if srcSize.width >= srcSize.height {
            w = maxSide
            h = srcSize.height > 0 ? maxSide * srcSize.height / srcSize.width : maxSide
        } else {
            h = maxSide
            w = srcSize.width > 0 ? maxSide * srcSize.width / srcSize.height : maxSide
        }
        let thumb = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            sourceImage.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        // 镜像中心贴住鼠标当前位置：无论按在图标还是名字上，跟手不飘。
        let grab = convert(event.locationInWindow, from: nil)
        draggingItem.setDraggingFrame(
            NSRect(x: grab.x - w / 2, y: grab.y - h / 2, width: w, height: h),
            contents: thumb)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartPoint = nil
        isDraggingSession = false
    }

    // MARK: NSDraggingSource
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return [.move, .copy]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragStartPoint = nil
        isDraggingSession = false
        // 文件被拖到外部（Finder/桌面/另一个托盘）后，刷新当前文件夹视图。
        if !operation.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.target?.reloadCurrentFolder()
            }
        }
    }

    private func loadThumbnail(url: URL) {
        if url.hasDirectoryPath { return }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 120, height: 120),
            scale: NSScreen.main?.backingScaleFactor ?? 2.0,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            DispatchQueue.main.async {
                self?.iconView.image = rep?.nsImage ?? NSWorkspace.shared.icon(forFile: url.path)
            }
        }
    }
}

// MARK: - 存储

/// 换总文件夹的结果。失败分两档：failedClean = 完整回滚，磁盘和记录与迁移前一致；
/// failedPartial = 部分托盘文件夹留在新位置，磁盘已不是迁移前的状态。
enum RootChangeOutcome {
    case success
    case failedClean
    case failedPartial([String])
}

final class FrameStore {
    static let rootKey = "DesktopGlassFrame.rootFolder"
    private let fileURL: URL
    private(set) var rootDirectory: URL
    var frames: [GlassFrame]
    private var watchers: [UUID: DispatchSourceFileSystemObject] = [:]
    private var watchedFDs: [UUID: Int32] = [:]
    // 结构性变更版本号（每托盘独立 + 总目录全局，NSLock 保护）：
    // 关托盘/子目录改名 → bump 该托盘；换总目录 → bump 总目录。
    // 后台文件任务入队时记下相关版本，执行前经主线程核对；不一致说明布局已变，
    // 旧任务作废——防止把文件搬进已删除的目录（孤儿）或搬进错误的文件夹。
    // 按托盘分维度：关 B 托盘不会误杀指向 A 托盘的排队任务。
    private let epochLock = NSLock()
    private var frameEpochs: [UUID: Int] = [:]
    private var _rootEpoch = 0
    func epoch(for id: UUID) -> Int { epochLock.withLock { frameEpochs[id, default: 0] + _rootEpoch } }
    func bumpFrame(_ id: UUID) { epochLock.withLock { frameEpochs[id, default: 0] += 1 } }
    func bumpRoot() { epochLock.withLock { _rootEpoch += 1 } }

    static func fileIdentity(_ url: URL) -> String? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = values[.systemNumber] as? NSNumber,
              let inode = values[.systemFileNumber] as? NSNumber else { return nil }
        return "\(device):\(inode)"
    }

    func desktopReturnPositions(for urls: [URL]) -> [String: CGPoint] {
        var result: [String: CGPoint] = [:]
        for url in urls {
            guard let key = Self.fileIdentity(url),
                  let point = frames.compactMap({ $0.desktopReturnPositions?[key] }).first else { continue }
            result[url.standardizedFileURL.path] = point
        }
        return result
    }

    func rememberDesktopDeparture(_ items: [FolderEntry], from frameID: UUID,
                                  identities: [String: String] = [:]) {
        guard let index = frames.firstIndex(where: { $0.id == frameID }) else { return }
        for item in items {
            guard let key = identities[item.name] ?? Self.fileIdentity(item.url),
                  let position = frames[index].positions[item.name] else { continue }
            if frames[index].desktopReturnPositions == nil { frames[index].desktopReturnPositions = [:] }
            frames[index].desktopReturnPositions?[key] = position
        }
        save()
    }

    func forgetDesktopReturns(for urls: [URL]) {
        let keys = Set(urls.compactMap(Self.fileIdentity))
        guard !keys.isEmpty else { return }
        for index in frames.indices {
            for key in keys { frames[index].desktopReturnPositions?.removeValue(forKey: key) }
        }
        save()
    }

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = appSupport.appendingPathComponent("DesktopGlassFrame", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("frames.json")

        if let saved = UserDefaults.standard.string(forKey: Self.rootKey) {
            rootDirectory = URL(fileURLWithPath: saved, isDirectory: true)
        } else {
            // 用户已经在桌面建好了「抽屉」，默认就用它。
            rootDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop/抽屉", isDirectory: true)
        }
        // 只有首次运行（用户没选过总目录）才自动创建；已保存的总目录若不存在
        // （被改名/外置盘未挂载），自动重建出一个空目录会让随后的认领逻辑
        // 把所有托盘当成「文件夹不存在」清掉状态——保留现场，跳过认领。
        if UserDefaults.standard.string(forKey: Self.rootKey) != nil {
            if !FileManager.default.fileExists(atPath: rootDirectory.path) {
                CrashGuard.writeLog("已保存的总目录不存在（\(rootDirectory.path)），不自动重建，保留原状态")
            }
        } else {
            try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        }

        // 主文件只要成功解码（哪怕空数组）就是有效状态——用户关掉全部托盘后保存的
        // 空列表不能被旧备份「复活」。备份只在主文件缺失或损坏时使用。
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([GlassFrame].self, from: data) {
            frames = saved
        } else if let data = try? Data(contentsOf: fileURL.appendingPathExtension("bak")),
                  let saved = try? JSONDecoder().decode([GlassFrame].self, from: data) {
            frames = saved
        } else {
            frames = []
        }
        // 每块托盘必须独占一个真实子文件夹；旧记录缺失时按标题恢复，避免两块板指向同一处。
        // 前提：总目录此刻可访问。外置盘未挂载/权限抖动时读不到子目录，
        // 若照常认领会把所有托盘当成「文件夹不存在」改写掉状态——直接跳过并保留原记录。
        let rootReadable = (try? FileManager.default.contentsOfDirectory(atPath: rootDirectory.path)) != nil
        if rootReadable {
            var claimedFolders = Set<String>()
            for index in frames.indices {
                if let existing = frames[index].folderName,
                   !claimedFolders.contains(existing),
                   FileManager.default.fileExists(atPath: folderURL(named: existing).path) {
                    claimedFolders.insert(existing)
                } else {
                    frames[index].folderName = nil
                }
            }
            for index in frames.indices where frames[index].folderName == nil {
                let base = sanitize(frames[index].title)
                var name = base
                var suffix = 2
                while claimedFolders.contains(name) {
                    name = "\(base) \(suffix)"
                    suffix += 1
                }
                frames[index].folderName = name
                claimedFolders.insert(name)
            }
            save()
        } else {
            CrashGuard.writeLog("启动时总目录不可访问（\(rootDirectory.path)），跳过托盘文件夹认领，保留原状态")
        }
    }

    var hasUserChosenRoot: Bool {
        UserDefaults.standard.string(forKey: Self.rootKey) != nil
    }

    func rememberRootChoice() {
        UserDefaults.standard.set(rootDirectory.standardizedFileURL.path, forKey: Self.rootKey)
    }

    @discardableResult
    func save() -> Bool {
        do {
            let data = try JSONEncoder().encode(frames)
            let temp = fileURL.appendingPathExtension("tmp")
            try data.write(to: temp, options: .atomic)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                // replaceItemAt 原子替换并把旧文件备份为 frames.json.bak。
                // 注意：默认 options 会在替换成功后删掉备份，必须显式加
                // .withoutDeletingBackupItem，否则启动时的 .bak 恢复路径永远是死代码。
                _ = try FileManager.default.replaceItem(at: fileURL, withItemAt: temp,
                                                        backupItemName: "frames.json.bak",
                                                        options: [.withoutDeletingBackupItem],
                                                        resultingItemURL: nil)
            } else {
                try FileManager.default.moveItem(at: temp, to: fileURL)
            }
            return true
        } catch {
            presentFileError(error, context: "保存托盘状态")
            return false
        }
    }

    func frame(id: UUID) -> GlassFrame? { frames.first { $0.id == id } }

    func update(_ frame: GlassFrame) {
        guard let index = frames.firstIndex(where: { $0.id == frame.id }) else { return }
        frames[index] = frame
        save()
    }

    /// 新增托盘。返回 false = 没建成（总目录缺失/子目录创建失败），调用方不要再建面板。
    @discardableResult
    func add(_ frame: GlassFrame) -> Bool {
        var frame = frame
        // 前置检查：总目录必须存在且是目录。缺失时绝不隐式重建——总目录被暂时
        // 改名时建出新的空目录，随后的认领/同步会把真实托盘状态当失效清掉。
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootDirectory.path, isDirectory: &isDir),
              isDir.boolValue else {
            presentFileError(CocoaError(.fileNoSuchFile),
                             context: "新增托盘中止：总文件夹当前不可访问（\(rootDirectory.path)）")
            return false
        }
        let base = sanitize(frame.title)
        var name = base
        var suffix = 2
        while FileManager.default.fileExists(atPath: folderURL(named: name).path) ||
                frames.contains(where: { $0.folderName == name }) {
            name = "\(base) \(suffix)"
            suffix += 1
        }
        frame.folderName = name
        // 先建目录、成功后再落记录：目录建不出来时不能留下指向空壳的托盘记录。
        // 不用 intermediates——绝不连带重建总目录。
        do {
            try FileManager.default.createDirectory(at: folderURL(for: frame),
                                                    withIntermediateDirectories: false)
        } catch {
            presentFileError(error, context: "创建托盘文件夹")
            return false
        }
        frames.append(frame)
        if !save() {
            // 状态没存住（磁盘满等）：面板会出现、重启后记录却消失，文件夹留在盘上——
            // 撤销新增并清掉刚建的目录。清理必须用 rmdir（只能删空目录）：save 报错
            // 先弹模态窗，弹窗期间 Finder/同步工具可能已往里放文件，removeItem 会
            // 把那些文件一起递归删掉。rmdir 非空即失败，文件原样保留并报告路径。
            frames.removeAll { $0.id == frame.id }
            let leftoverDir = folderURL(for: frame)
            let cleaned = rmdir(leftoverDir.path) == 0
            presentFileError(CocoaError(.fileWriteVolumeReadOnly),
                             context: cleaned
                                ? "新增托盘中止：托盘状态未能保存（请检查磁盘空间与权限）"
                                : "新增托盘中止：状态未能保存；回滚时发现目录里已有文件，已原样保留：\n\(leftoverDir.path)")
            return false
        }
        return true
    }

    func remove(id: UUID) {
        watchers[id]?.cancel()      // cancel 触发 cancelHandler 里的 close(fd)
        watchers.removeValue(forKey: id)
        watchedFDs.removeValue(forKey: id)   // 必须同步清理，否则残留已 close 的 fd
        frames.removeAll { $0.id == id }
        bumpFrame(id)               // 作废已入队、指向这块托盘的后台文件任务
        save()
    }

    // MARK: 子文件夹

    private func sanitize(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "托盘" : String(cleaned.prefix(40))
    }

    private func folderURL(named name: String) -> URL {
        rootDirectory.appendingPathComponent(name, isDirectory: true)
    }

    /// 只计算子目录 URL，绝不创建目录。任何创建都必须走显式路径
    /// （ensureFolderExists / add()），否则总目录被暂时改名时会连它一起重建出来，
    /// 随后的启动认领/同步就会把已有托盘状态当成失效清掉。
    func folderURL(for frame: GlassFrame) -> URL {
        folderURL(named: frame.folderName ?? sanitize(frame.title))
    }

    /// 纯计算 URL，零副作用。任何调用点都不会再隐式补建目录——Finder 刚把子目录
    /// 改名而监听尚未认领时，隐式补建旧名空目录会让新文档写进孤儿目录。
    /// 补建只允许发生在 syncFrame 的显式 ensureFolderExists（先认领改名、
    /// 确认总目录可读之后的同步流程）。
    func folder(for frame: GlassFrame) -> URL {
        folderURL(for: frame)
    }

    /// 总目录本身存在时才补建缺失的子目录（不用 intermediates，绝不连带建总目录）。
    func ensureFolderExists(for frame: GlassFrame) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootDirectory.path, isDirectory: &isDir),
              isDir.boolValue else { return }
        try? FileManager.default.createDirectory(at: folderURL(for: frame), withIntermediateDirectories: false)
    }

    func isRootReadable() -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: rootDirectory.path)) != nil
    }

    /// 关闭窗口前先把实际文件搬回总文件夹；任何一步失败就回滚，保留窗口和子文件夹。
    func emptyAndRemoveFolder(for frame: GlassFrame) throws {
        // 只用纯计算 URL、绝不补建：Finder 刚把子目录改名而监听尚未认领时，
        // folder(for:) 的补建副作用会造出旧名空目录再被删掉，真正的目录
        // 留在磁盘上却失去托盘归属。缺失就如实报错中止关闭。
        let folder = folderURL(for: frame)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw CocoaError(.fileNoSuchFile,
                             userInfo: [NSLocalizedDescriptionKey:
                                "托盘子文件夹不存在（可能已被移动或改名）：\(folder.path)"])
        }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        var moved: [(from: URL, to: URL)] = []
        do {
            for file in files where file.lastPathComponent != ".DS_Store" {
                let target = uniqueURL(for: file.lastPathComponent, in: rootDirectory)
                try FileManager.default.moveItem(at: file, to: target)
                moved.append((file, target))
            }
            // Finder 的 .DS_Store 可重建；其它隐藏项一律按真实文件搬走。
            try FileManager.default.removeItem(at: folder)
        } catch {
            for item in moved.reversed() {
                try? FileManager.default.moveItem(at: item.to, to: item.from)
            }
            throw error
        }
    }

    /// 子文件夹当前内容 = 托盘的真实内容。隐藏文件（含 .DS_Store）跳过。
    func entries(for frame: GlassFrame) -> [FolderEntry] {
        let url = folder(for: frame)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return Self.buildEntries(names: names, url: url)
    }

    /// 与 entries(for:) 相同，但目录读不到时返回 nil（而不是当成空文件夹）。
    /// 读取检查必须零副作用：目录缺失就如实返回 nil，绝不顺手补建。
    func entriesIfReadable(for frame: GlassFrame) -> [FolderEntry]? {
        let name = frame.folderName ?? sanitize(frame.title)
        let url = folderURL(named: name)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return nil }
        return Self.buildEntries(names: names, url: url)
    }

    private static func buildEntries(names: [String], url: URL) -> [FolderEntry] {
        names
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .compactMap { name in
                let fileURL = url.appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir) else { return nil }
                let modified = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
                return FolderEntry(name: name, url: fileURL, modified: modified)
            }
    }

    // MARK: 文件夹监听（实时镜像的关键）

    func watch(frame: GlassFrame, onChange: @escaping () -> Void) {
        unwatch(frame.id)
        let url = folder(for: frame)
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }
        source.resume()
        watchers[frame.id] = source
        watchedFDs[frame.id] = fd
    }

    func unwatch(_ id: UUID) {
        watchers[id]?.cancel()
        watchers.removeValue(forKey: id)
        watchedFDs.removeValue(forKey: id)
    }

    func unwatchAll() {
        for (_, source) in watchers { source.cancel() }
        watchers.removeAll()
        watchedFDs.removeAll()
    }

    // MARK: 重命名

    /// 重命名托盘：子文件夹跟着改名。
    /// 目标名磁盘上已存在但没被别的托盘认领时，把旧文件夹内容并进去、删掉旧壳——
    /// 「托盘改名 = 归入那个文件夹」，而不是静默失败。
    func renameFolderIfNeeded(for frameID: UUID, newTitle: String) {
        guard let index = frames.firstIndex(where: { $0.id == frameID }) else { return }
        let oldName = frames[index].folderName ?? sanitize(frames[index].title)
        let newName = sanitize(newTitle)
        guard newName != oldName else { return }
        let oldURL = folderURL(named: oldName)
        let newURL = folderURL(named: newName)
        let claimedByOther = frames.contains { $0.id != frameID && $0.folderName == newName }

        if !FileManager.default.fileExists(atPath: newURL.path),
           FileManager.default.fileExists(atPath: oldURL.path) {
            do {
                try FileManager.default.moveItem(at: oldURL, to: newURL)
                frames[index].folderName = newName
                bumpFrame(frames[index].id)
                save()
            } catch {
                presentFileError(error, context: "重命名托盘文件夹")
            }
            return
        }
        if !claimedByOther, FileManager.default.fileExists(atPath: newURL.path),
           FileManager.default.fileExists(atPath: oldURL.path) {
            do {
                let items = (try? FileManager.default.contentsOfDirectory(atPath: oldURL.path)) ?? []
                var movedItems: [(from: URL, to: URL)] = []
                do {
                    for item in items where item != ".DS_Store" {
                        let destination = uniqueURL(for: item, in: newURL)
                        try FileManager.default.moveItem(at: oldURL.appendingPathComponent(item), to: destination)
                        movedItems.append((oldURL.appendingPathComponent(item), destination))
                    }
                    try FileManager.default.removeItem(at: oldURL)
                    frames[index].folderName = newName
                    bumpFrame(frames[index].id)
                    save()
                } catch {
                    // 中途失败：把已搬走的逆序搬回旧文件夹；回滚本身也失败时，
                    // 如实列出每个文件的实际去向，绝不能谎报「托盘保持原样」。
                    var rollbackFailures: [String] = []
                    for m in movedItems.reversed() {
                        do {
                            try FileManager.default.moveItem(at: m.to, to: m.from)
                        } catch {
                            rollbackFailures.append("「\(m.to.lastPathComponent)」留在 \(m.to.path)")
                        }
                    }
                    if rollbackFailures.isEmpty {
                        presentFileError(error, context: "合并托盘文件夹（已回滚，托盘保持原样）")
                    } else {
                        GlassDialog.info(title: "合并托盘文件夹失败",
                                         message: "部分文件未能搬回原处，实际位置：\n"
                                            + rollbackFailures.joined(separator: "\n"))
                    }
                }
            }
        }
    }

    /// Finder 里直接改了子文件夹名：靠 fd 的 inode 反查它现在的名字，认领回来并联动标题。
    /// 返回是否发生了认领（调用方随后刷新 UI）。
    func adoptRenamedFolder(for frameID: UUID) -> Bool {
        guard let index = frames.firstIndex(where: { $0.id == frameID }),
              let fd = watchedFDs[frameID] else { return false }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return false }
        let dirs = (try? FileManager.default.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil, options: [])) ?? []
        for dir in dirs {
            var dirSt = stat()
            guard stat(dir.path, &dirSt) == 0, dirSt.st_ino == st.st_ino else { continue }
            let newName = dir.lastPathComponent
            guard frames[index].folderName != newName else { return false }
            frames[index].folderName = newName
            frames[index].title = newName
            bumpFrame(frameID)
            save()
            return true
        }
        return false
    }

    // MARK: 文件进出

    /// 同卷个人文件按 Finder 常规移动；外置卷、应用和资料库来源只复制，原件留下。
    /// targetFolderOverride / rootPathOverride：后台队列任务传入主线程预先确认好的
    /// 目标目录与总目录路径，不从可变的 FrameStore 字段重新推导（换总目录进行中防搬错）。
    func importURL(_ url: URL, into frame: GlassFrame,
                   targetFolderOverride: URL? = nil, rootPathOverride: String? = nil) -> URL {
        let source = url.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = rootPathOverride ?? rootDirectory.standardizedFileURL.path
        let targetFolder = (targetFolderOverride ?? folder(for: frame)).standardizedFileURL
        if source.deletingLastPathComponent().path == targetFolder.path { return source }
        // 不允许把总文件夹或某块托盘文件夹本身拖进自己的子目录。
        if source.path == root || targetFolder.path.hasPrefix(source.path + "/") { return url }

        guard source.path != "/", source.path != "/System",
              source.path != "/Applications",
              source.path != home.appendingPathComponent("Library").path else { return url }
        let shouldMove = source.path.hasPrefix(home.path + "/") &&
            !source.path.hasPrefix(home.appendingPathComponent("Library").path + "/")
        let target = uniqueURL(for: source.lastPathComponent, in: targetFolder)
        do {
            if shouldMove {
                try FileManager.default.moveItem(at: source, to: target)
            } else {
                try FileManager.default.copyItem(at: source, to: target)
            }
            return target
        } catch {
            presentFileError(error, context: shouldMove ? "移动文件" : "复制文件")
            return url
        }
    }

    /// 粘贴（拷贝语义）：把剪贴板里的文件复制进子文件夹，返回最终地址；不搬动原件。
    func copyURL(_ url: URL, into frame: GlassFrame,
                 targetFolderOverride: URL? = nil, rootPathOverride: String? = nil) -> URL? {
        let source = url.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = rootPathOverride ?? rootDirectory.standardizedFileURL.path
        let targetFolder = (targetFolderOverride ?? folder(for: frame)).standardizedFileURL
        if source.deletingLastPathComponent().path == targetFolder.path { return nil }
        if source.path == root || targetFolder.path.hasPrefix(source.path + "/") { return nil }
        let protected = ["/", "/System", "/Applications", home.appendingPathComponent("Library").path]
        guard !protected.contains(where: { source.path == $0 || source.path.hasPrefix($0 + "/") }) else { return nil }
        let target = uniqueURL(for: source.lastPathComponent, in: targetFolder)
        do {
            try FileManager.default.copyItem(at: source, to: target)
            return target
        } catch {
            presentFileError(error, context: "复制文件")
            return nil
        }
    }

    /// 移到废纸篓（Finder 删除语义）。返回是否成功，供调用方如实统计 toast 数量。
    @discardableResult
    func trashURL(_ url: URL) -> Bool {
        do {
            try FileManager.default.trashItem(at: url.standardizedFileURL, resultingItemURL: nil)
            return true
        } catch {
            presentFileError(error, context: "移到废纸篓")
            return false
        }
    }

    /// 移回桌面：文件真实搬回桌面根目录，返回新地址。
    func exportToDesktop(url fileURL: URL) -> URL? {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        let source = fileURL.standardizedFileURL
        if source.deletingLastPathComponent().path == desktop.standardizedFileURL.path { return fileURL }
        let target = uniqueURL(for: source.lastPathComponent, in: desktop)
        do {
            try FileManager.default.moveItem(at: source, to: target)
            return target
        } catch {
            presentFileError(error, context: "移回桌面")
            return nil
        }
    }

    func uniqueURL(for filename: String, in directory: URL) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = directory.appendingPathComponent(filename)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let suffix = ext.isEmpty ? " (\(index))" : " (\(index)).\(ext)"
            candidate = directory.appendingPathComponent(base + suffix)
            index += 1
        }
        return candidate
    }

    /// 更换总文件夹：所有托盘子文件夹一起搬过去，记录同步。
    /// 失败必须区分「完整回滚」（磁盘与记录和迁移前完全一致）和「部分回滚失败」
    /// （有托盘文件夹留在新位置）——后者根路径虽未变，文件已不在原处，
    /// 调用方不能只比路径就宣称「没有变化」。
    func changeRoot(to newRoot: URL) -> RootChangeOutcome {
        let target = newRoot.standardizedFileURL
        let current = rootDirectory.standardizedFileURL
        guard target.path != current.path else { return .failedClean }
        guard !target.path.hasPrefix(current.path + "/") else { return .failedClean }
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            presentFileError(error, context: "创建新总文件夹")
            return .failedClean
        }

        // 迁移前置检查：任何一块托盘的子目录缺失或不是文件夹就中止。之前是跳过缺失项继续，
        // 结果那块托盘的文件留在旧根、记录却指向新根，图标凭空消失。
        // fileExists 只查存在性——子目录被外部换成同名普通文件时会把文件当目录搬走。
        for frame in frames {
            let oldFolder = folderURL(for: frame)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: oldFolder.path, isDirectory: &isDir),
                  isDir.boolValue else {
                presentFileError(CocoaError(.fileNoSuchFile),
                                 context: "更换总文件夹中止：托盘「\(frame.title)」的子文件夹不存在或不是文件夹（\(oldFolder.path)）")
                return .failedClean
            }
        }

        // 迁移失败的物理回滚逐项核对；有搬不回的文件就如实列出实际去向。
        func rollbackMigration(_ moved: [(from: URL, to: URL)]) -> [String] {
            var failures: [String] = []
            for item in moved.reversed() {
                do {
                    try FileManager.default.moveItem(at: item.to, to: item.from)
                } catch {
                    failures.append("「\(item.to.lastPathComponent)」留在 \(item.to.path)")
                }
            }
            return failures
        }
        func reportRollback(_ origin: String, _ failures: [String]) {
            if failures.isEmpty {
                presentFileError(CocoaError(.fileWriteUnknown), context: origin + "（已回滚，一切保持原样）")
            } else {
                GlassDialog.info(title: origin + "失败",
                                 message: "部分文件未能搬回原处，实际位置：\n" + failures.joined(separator: "\n"))
            }
        }

        var moved: [(from: URL, to: URL)] = []
        var updated = frames
        for frameIndex in frames.indices {
            let frame = frames[frameIndex]
            let oldFolder = folderURL(for: frame)
            let name = frame.folderName ?? sanitize(frame.title)
            let destination = target.appendingPathComponent(name, isDirectory: true)
            var finalURL = destination
            var suffix = 2
            while FileManager.default.fileExists(atPath: finalURL.path) {
                finalURL = target.appendingPathComponent("\(name) \(suffix)", isDirectory: true)
                suffix += 1
            }
            do {
                try FileManager.default.moveItem(at: oldFolder, to: finalURL)
                moved.append((oldFolder, finalURL))
                updated[frameIndex].folderName = finalURL.lastPathComponent
            } catch {
                let failures = rollbackMigration(moved)
                if failures.isEmpty {
                    presentFileError(error, context: "更换总文件夹（已回滚）")
                } else {
                    reportRollback("更换总文件夹", failures)
                }
                return failures.isEmpty ? .failedClean : .failedPartial(failures)
            }
        }
        rootDirectory = target
        let originalFrames = frames
        frames = updated
        rememberRootChoice()
        if save() {
            bumpRoot()
            return .success
        }
        // 状态持久化失败：物理搬回 + 记录还原，保持磁盘与 frames.json 一致，
        // 绝不能「文件夹已搬走而记录还指向旧根」。
        let failures = rollbackMigration(moved)
        rootDirectory = current
        frames = originalFrames
        rememberRootChoice()
        save()
        if !failures.isEmpty {
            GlassDialog.info(title: "更换总文件夹失败",
                             message: "状态未能保存，回滚时有部分文件留在新位置，实际位置：\n"
                                + failures.joined(separator: "\n"))
        }
        return failures.isEmpty ? .failedClean : .failedPartial(failures)
    }
}

// MARK: - App

final class FrameApp: NSObject, NSApplicationDelegate {
    private let store = FrameStore()
    private var panels: [UUID: TrayPanel] = [:]
    private var panelViews: [UUID: FramePanelView] = [:]
    private var syncDebounce: DispatchWorkItem?
    private var pendingSyncs: Set<UUID> = []
    // 文件搬运专用串行队列：大文件复制/移动不再卡主线程（拖拽会话与 UI 冻结）。
    // 只有纯 FileManager I/O 在这里跑（store 的 importURL/copyURL/exportToDesktop/
    // trashURL/uniqueURL 都是无状态的纯 I/O）；store 状态与 UI 更新一律回主线程。
    private let fileIOQueue = DispatchQueue(label: "trayapp.fileio", qos: .userInitiated)
    // didResignKey block 观察者的 token 按面板保存，关面板时移除，避免反复建托盘累积。
    private var resignKeyObservers: [UUID: NSObjectProtocol] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if store.frames.isEmpty {
            let first = GlassFrame(title: "托盘 1", frame: validFrame(NSRect(x: 260, y: 260, width: 500, height: 350)))
            guard store.add(first) else {
                // 总目录暂时缺失（被改名/外置盘未挂载）：没有任何面板可显示、
                // 也没有界面入口能修复。明确报错后退出，等用户恢复目录再启动——
                // 绝不能无窗口地以 accessory 模式占着单例锁空转。
                GlassDialog.info(title: "无法启动",
                                 message: "总文件夹当前不可访问：\n\(store.rootDirectory.path)\n\n请恢复该文件夹（或改回原名）后再启动桌面托盘。")
                NSApp.terminate(nil)
                return
            }
        }
        for frame in store.frames {
            createPanel(for: frame)
        }
        for frame in store.frames {
            syncFrame(frame.id)
        }

        // 默认总文件夹已指向桌面的「抽屉」，不再首启弹窗打断（runModal 会挂起主队列，
        // 连带挂起文件夹监听）；想换位置走右键「选择存放文件夹…」。
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.unwatchAll()
    }

    // MARK: 面板生命周期

    private func createPanel(for frame: GlassFrame) {
        let panel = TrayPanel(
            contentRect: validFrame(frame.frame),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // 玻璃只在视觉上透明；空白画布仍接收框选、右键和拖放。
        panel.ignoresMouseEvents = false
        panel.hasShadow = false
        panel.title = frame.title
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 3)

        let content = FramePanelView(frameModel: frame)
        content.frameFolderURL = store.folder(for: frame)
        panel.contentView = content
        wire(content: content, frameID: frame.id)
        // 点到桌面或别的 App 时，托盘里的选中让位；自家 Quick Look 接管不算。
        // token 必须保存：block 观察者不 remove 会随每次重建托盘一直累积。
        let resignKeyToken = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                               object: panel, queue: .main) { [weak self, frameID = frame.id] _ in
            if let preview = QLPreviewPanel.shared(), preview.isVisible { return }
            self?.panelViews[frameID]?.clearSelection()
        }
        resignKeyObservers[frame.id] = resignKeyToken

        panels[frame.id] = panel
        panelViews[frame.id] = content
        panel.orderFrontRegardless()
    }

    private func wire(content: FramePanelView, frameID: UUID) {
        content.onFrameChanged = { [weak self] frame in
            guard let self else { return }
            var updated = frame
            updated.frame = self.panels[frameID]?.frame ?? frame.frame
            self.store.update(updated)
        }
        content.onSetFrame = { [weak self] frame, newFrame in
            guard let self, let panel = self.panels[frame.id] else { return }
            panel.setFrame(self.validFrame(newFrame), display: true)
        }
        content.onMoveItems = { [weak self] names, sourceID, targetID, positions in
            self?.moveItems(names: names, from: sourceID, to: targetID, positions: positions)
        }
        content.onImportURL = { [weak self] url, frame in
            guard let self else { return url }
            return self.store.importURL(url, into: frame)
        }
        content.onImportBatch = { [weak self] urls, frame, positions, folderPath in
            self?.importBatch(urls, frame: frame, positions: positions, folderPath: folderPath)
        }
        content.onImport = { [weak self] incoming in
            self?.importItems(incoming, into: frameID)
        }
        content.onDraggedOut = { [weak self] items, screenPoint, operation in
            self?.draggedOut(items, from: frameID, at: screenPoint, operation: operation)
        }
        content.onDesktopReturnPositions = { [weak self] urls in
            self?.store.desktopReturnPositions(for: urls) ?? [:]
        }
        content.onReturnToDesktop = { [weak self] items in
            self?.returnItemsToDesktop(items, from: frameID)
        }
        content.onRenameItem = { [weak self] name in
            self?.renameItem(name, in: frameID)
        }
        content.onDuplicateItems = { [weak self] names in
            self?.duplicateItems(names, in: frameID)
        }
        content.onNewFrame = { [weak self] in self?.addFrame() }
        content.onCloseFrame = { [weak self] in self?.closeFrameWithConfirmation(id: frameID) }
        content.onChooseRoot = { [weak self] in self?.chooseRoot() }
        content.onRevealRoot = { [weak self] in NSWorkspace.shared.open(self?.store.rootDirectory ?? URL(fileURLWithPath: "/")) }
        content.onRename = { [weak self] in self?.renameFrame(id: frameID) }
        content.onQuit = { NSApp.terminate(nil) }
        content.onTrashItems = { [weak self] names in
            self?.trashItems(names: names, in: frameID)
        }
        content.onNewFolder = { [weak self] in self?.createNewFolder(in: frameID) }
        content.onNewTextDocument = { [weak self] in self?.createNewTextDocument(in: frameID) }
        content.onPaste = { [weak self] in self?.pasteInto(frameID: frameID) }
        // 开机自启的开关动作在 titlePill.toggleLaunchAtLogin() 里已直接执行（LoginItem.setEnabled），
        // 这里无需再刷新任何 UI 状态，故为空。保留钩子仅为对齐其它回调的写法。
        content.onToggleLaunchAtLogin = { }
        // 缩放滑块在任意托盘调节后，其它托盘按同一比例重排（scale 已全局生效）。
        content.onThumbnailScaleChanged = { [weak self] _, ratio in
            guard let self else { return }
            for (id, view) in self.panelViews where id != frameID {
                view.rescalePositions(by: ratio)
            }
        }
        content.onClearFinderSelection = { [weak self] in
            self?.clearFinderDesktopSelection()
        }
        content.onImportIntoFolder = { [weak self] urls, folderName in
            self?.importIntoFolder(urls, folderName: folderName, frameID: frameID)
        }
        content.onMoveItemsIntoFolder = { [weak self] names, folderName, sourceID in
            self?.moveItemsIntoFolder(names, folderName: folderName, sourceFrameID: sourceID, targetFrameID: frameID)
        }
        content.onRescueCancelledDrop = { [weak self] screenPoint, items, sourceID in
            self?.rescueCancelledDrop(at: screenPoint, items: items, sourceFrameID: sourceID)
        }
    }

    // MARK: 文件夹 → 托盘（实时镜像核心）

    private func scheduleSync(_ frameID: UUID) {
        pendingSyncs.insert(frameID)
        syncDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let ids = self.pendingSyncs
            self.pendingSyncs = []
            for id in ids { self.syncFrame(id) }
        }
        syncDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// 以子文件夹内容为准刷新托盘：新文件给空位，消失的文件清位置记录。
    private func syncFrame(_ frameID: UUID) {
        guard let content = panelViews[frameID] else { return }
        // 文件夹被外部改名（watcher 的 rename 事件）：认领新名字，标题跟着文件夹走。
        if store.adoptRenamedFolder(for: frameID), let renamed = store.frame(id: frameID) {
            panels[frameID]?.title = renamed.title
        }
        guard var frame = store.frame(id: frameID) else { return }
        // 总目录不可读（外置盘未挂载/被改名）：读失败绝不能当空文件夹清掉图标位置，
        // 跳过本次同步并定时重试（之前直接 return，目录恢复后只能重启才能重新同步）。
        guard store.isRootReadable() else {
            CrashGuard.writeLog("同步跳过：总目录暂时不可访问，10 秒后重试")
            scheduleUnreadableRetry(frameID)
            return
        }
        // 总目录可读而子目录缺失 = 文件夹被外部删除：显式补建（绝不连带建总目录），
        // 托盘如实显示为空。
        store.ensureFolderExists(for: frame)
        // 单次读取；仍读不到（罕见竞态）同样走重试，不当空文件夹处理。
        guard let current = store.entriesIfReadable(for: frame) else {
            CrashGuard.writeLog("同步跳过：托盘「\(frame.title)」子文件夹暂时不可读，10 秒后重试")
            scheduleUnreadableRetry(frameID)
            return
        }
        let names = Set(current.map(\.name))

        var changed = false
        var removed = false
        for gone in frame.positions.keys where !names.contains(gone) {
            frame.positions.removeValue(forKey: gone)
            changed = true
            removed = true
        }
        for entry in current where frame.positions[entry.name] == nil {
            frame.positions[entry.name] = nextFreePosition(in: frame, width: content.bounds.width)
            changed = true
        }
        // 有图标离开时全体前移补位，保持网格连续。
        if removed {
            compactGrid(&frame.positions, width: content.bounds.width, pinned: frame.pinnedNames ?? [])
        }
        if changed { store.update(frame) }
        content.reload(frameModel: frame, entries: current)
        content.growToFitIfNeeded()

        // 重新挂监听：文件夹被外部改名/删除后旧 fd 会失效，每次同步后重挂最稳。
        store.watch(frame: frame) { [weak self] in
            self?.scheduleSync(frameID)
        }
    }

    /// 文件夹暂时不可读时的恢复入口：10 秒后重试同步（托盘已关则停止）。
    /// 之前读失败直接 return，watcher 也建立不起来，目录恢复后只能靠重启才能重新同步。
    private func scheduleUnreadableRetry(_ frameID: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.panelViews[frameID] != nil else { return }
            self.syncFrame(frameID)
        }
    }

    private func nextFreePosition(in frame: GlassFrame, width: CGFloat) -> CGPoint {
        let inset = FramePanelView.contentInset
        let cell = TrayItemView.cellSize
        let maxCol = max(0, Int((width - inset.left - inset.right) / cell.width))
        var row = 0
        while row < 500 {
            for col in 0...max(0, maxCol) {
                let candidate = CGPoint(x: inset.left + CGFloat(col) * cell.width,
                                        y: inset.top + CGFloat(row) * cell.height)
                let occupied = frame.positions.values.contains {
                    abs($0.x - candidate.x) < 1 && abs($0.y - candidate.y) < 1
                }
                if !occupied { return candidate }
            }
            row += 1
        }
        return CGPoint(x: inset.left, y: inset.top)
    }

    private func validFrame(_ frame: NSRect) -> NSRect {
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return frame }
        let size = NSSize(width: min(max(frame.width, 240), visible.width - 8),
                          height: min(max(frame.height, 180), visible.height - 8))
        return NSRect(x: min(max(frame.minX, visible.minX + 4), visible.maxX - size.width - 4),
                      y: min(max(frame.minY, visible.minY + 4), visible.maxY - size.height - 4),
                      width: size.width, height: size.height)
    }

    // MARK: 新建 / 重命名 / 关闭

    private func addFrame() {
        let offset = CGFloat((store.frames.count % 5)) * 28
        let frame = GlassFrame(
            title: "托盘 \(store.frames.count + 1)",
            frame: validFrame(NSRect(x: 260 + offset, y: 260 - offset, width: 420, height: 320))
        )
        guard store.add(frame) else { return }   // 目录没建成就不建面板
        createPanel(for: frame)
        syncFrame(frame.id)
    }

    private func renameFrame(id: UUID) {
        guard let frame = store.frame(id: id) else { return }
        NSApp.activate(ignoringOtherApps: true)
        guard let input = GlassDialog.prompt(
            title: "重命名托盘",
            message: "标题同时也是它在总文件夹里的子文件夹名。",
            text: frame.title) else { return }
        let name = String(input.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        // 原名原样提交：没有任何实际变更，直接返回——否则结构变更通道会白白发
        // 该托盘版本、作废排队中的文件任务。
        guard !name.isEmpty, name != frame.title else { return }

        // 改名含子文件夹搬移/合并（磁盘 I/O），和文件队列并发会让在途批次把
        // 后续文件写进已消失的旧目录：先 bump 该托盘版本作废排队任务、
        // 等在途 I/O 跑完，再改标题与磁盘目录。
        performStructuralChange(frameIDs: [id]) { [weak self] in
            guard let self else { return }
            // 队列等待期间状态可能又变：按 ID 重读，不存在就放弃。
            guard let current = self.store.frame(id: id) else { return }
            var updated = current
            updated.title = name
            self.store.update(updated)
            self.store.renameFolderIfNeeded(for: id, newTitle: name)
            if let renamed = self.store.frame(id: id) {
                self.panels[id]?.title = renamed.title
                self.scheduleSync(id)
            }
        }
    }

    /// 关闭托盘：内容归还总文件夹，删除该托盘的子文件夹。
    private func closeFrameWithConfirmation(id: UUID) {
        guard let frame = store.frame(id: id) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let confirmed = GlassDialog.confirm(
            title: "关闭「\(frame.title)」窗口？",
            message: "框内文件会移回总文件夹「\(store.rootDirectory.lastPathComponent)」，随后删除「\(frame.folderName ?? frame.title)」子文件夹。",
            confirmTitle: "移回并关闭",
            destructive: true)
        guard confirmed else { return }

        // 关托盘是结构性变更：先作废指向它的排队文件任务、等在途任务跑完再动磁盘，
        // 防止「文件搬进正在被删除的子文件夹」变成孤儿。
        performStructuralChange(frameIDs: [id]) { [weak self] in
            guard let self else { return }
            // 回调执行时按 ID 重读当前 frame：队列等待期间可能先跑了一次换总目录，
            // 同名目录冲突会把子目录改存成「A 2」，旧快照里的 folderName 已过期——
            // 按旧名定位会清空新总目录里无关的同名目录。frame 没了就取消关闭。
            guard let current = self.store.frame(id: id) else {
                GlassDialog.info(title: "无法关闭",
                                 message: "托盘状态刚发生了变化（可能正在迁移总文件夹），请重新执行关闭。")
                return
            }
            do {
                try self.store.emptyAndRemoveFolder(for: current)
            } catch {
                GlassDialog.error(error, context: "文件未能全部移回，托盘保持原样")
                return
            }

            self.store.unwatch(id)
            if let token = self.resignKeyObservers.removeValue(forKey: id) {
                NotificationCenter.default.removeObserver(token)
            }
            self.panels[id]?.orderOut(nil)
            self.panels[id] = nil
            self.panelViews[id] = nil
            self.store.remove(id: id)

            if self.panels.isEmpty {
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: 文件进出

    /// 后台文件任务开始前的统一闸门：回主线程核对相关托盘的版本与存在性。
    /// 版本按托盘独立（关 B 托盘不会误杀指向 A 的任务），换总目录推全局根版本。
    /// 排队期间若发生关托盘/换总目录/子目录改名（版本变化），任务作废，
    /// 防止把文件搬进已删除的目录（变成界面无法访问的孤儿）或搬进错误文件夹。
    private func fileTaskValid(frameIDs: [UUID], epochs: [UUID: Int]) -> Bool {
        DispatchQueue.main.sync { [weak self] in
            guard let self else { return false }
            return frameIDs.allSatisfy { id in
                self.store.epoch(for: id) == epochs[id] && self.store.frame(id: id) != nil
            }
        }
    }

    /// 结构性变更（关托盘、换总目录）的串行闸门：
    /// ① 先 bump 版本，拒绝所有还没过闸的后台任务；
    /// ② 用 barrier 等在途文件任务全部跑完；
    /// ③ 回主线程执行真正的磁盘/状态变更。
    /// 全程异步，主线程绝不同步等待文件队列。
    private func performStructuralChange(frameIDs: [UUID] = [], bumpRoot: Bool = false,
                                         _ work: @escaping () -> Void) {
        for id in frameIDs { store.bumpFrame(id) }
        if bumpRoot { store.bumpRoot() }
        fileIOQueue.async(flags: .barrier) { [weak self] in
            DispatchQueue.main.async {
                guard self != nil else { return }
                work()
            }
        }
    }

    /// 外部拖入文件的批量落盘：纯 I/O 在后台串行队列（大文件复制/移动不冻结 UI），
    /// 完成后回主线程按拖拽时算好的布局上屏。
    private func importBatch(_ urls: [URL], frame: GlassFrame,
                             positions: [String: CGPoint], folderPath: String?) {
        let epochs = captureEpochs([frame.id])
        let targetFolder = store.folder(for: frame).standardizedFileURL
        let rootPath = store.rootDirectory.standardizedFileURL.path
        fileIOQueue.async { [weak self] in
            guard let self, self.fileTaskValid(frameIDs: [frame.id], epochs: epochs) else { return }
            let store = self.store
            var incoming: [(original: URL, final: URL, position: CGPoint)] = []
            for url in urls {
                let finalURL = store.importURL(url, into: frame, targetFolderOverride: targetFolder,
                                               rootPathOverride: rootPath)
                guard finalURL.deletingLastPathComponent().standardizedFileURL.path == targetFolder.path else { continue }
                incoming.append((url, finalURL, positions[url.standardizedFileURL.path] ?? .zero))
            }
            guard !incoming.isEmpty else { return }
            DispatchQueue.main.async {
                guard self.panelViews[frame.id] != nil else { return }
                self.importItems(incoming, into: frame.id)
            }
        }
    }

    private func importItems(_ incoming: [(original: URL, final: URL, position: CGPoint)], into frameID: UUID) {
        guard var frame = store.frame(id: frameID), let content = panelViews[frameID] else { return }
        // 拖进来 = 插进拖放落点那个格，其余图标顺延让位。
        let group = incoming.map { $0.final.lastPathComponent }
        let drop = incoming.first?.position ?? .zero
        insertGroup(group, atDrop: drop, into: &frame.positions, width: content.bounds.width,
                    pinned: frame.pinnedNames ?? [])
        store.update(frame)
        store.forgetDesktopReturns(for: incoming.map(\.final))
        // 文件已经真实 move 进子文件夹；主动同步一次更跟手，watcher 兜底。
        syncFrame(frameID)
        panelViews[frameID]?.growToFitIfNeeded()
        if !incoming.isEmpty {
            panelViews[frameID]?.showToast("已添加 ×\(incoming.count)")
        }
    }

    // MARK: 网格流（自动对齐 / 自动排列 / 自动补位）

    private func gridColumns(width: CGFloat) -> Int {
        let inset = FramePanelView.contentInset
        return max(1, Int((width - inset.left - inset.right) / TrayItemView.cellSize.width))
    }

    private func gridPoint(index: Int, columns: Int) -> CGPoint {
        let inset = FramePanelView.contentInset
        return CGPoint(x: inset.left + CGFloat(index % columns) * TrayItemView.cellSize.width,
                       y: inset.top + CGFloat(index / columns) * TrayItemView.cellSize.height)
    }

    private func orderedNames(_ positions: [String: CGPoint], pinned: [String] = []) -> [String] {
        let pinIndex = Dictionary(uniqueKeysWithValues: pinned.enumerated().map { ($1, $0) })
        return positions.sorted { a, b in
            switch (pinIndex[a.key], pinIndex[b.key]) {
            case let (ia?, ib?): return ia < ib
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            if abs(a.value.y - b.value.y) > 1 { return a.value.y < b.value.y }
            return a.value.x < b.value.x
        }.map(\.key)
    }

    /// 把一组名字插到落点格的序列位置，其余图标整体顺延——iOS 主屏式的重排。
    /// 置顶项不参与落点插入：无论拖到哪，重排后都按置顶顺序占最前排。
    private func insertGroup(_ group: [String], atDrop drop: CGPoint,
                             into positions: inout [String: CGPoint], width: CGFloat,
                             pinned: [String] = []) {
        let cols = gridColumns(width: width)
        let inset = FramePanelView.contentInset
        let cell = TrayItemView.cellSize
        var seq = orderedNames(positions, pinned: pinned).filter { !group.contains($0) }
        let pinSet = Set(pinned)
        let pinnedGroup = pinned.filter { group.contains($0) }
        let plainGroup = group.filter { !pinSet.contains($0) }
        let col = min(max(0, Int(round((drop.x - inset.left) / cell.width))), max(0, cols - 1))
        let row = min(max(0, Int(round((drop.y - inset.top) / cell.height))), 100_000)
        var index = min(max(0, row &* cols &+ col), seq.count)
        for name in plainGroup {
            seq.insert(name, at: min(index, seq.count))
            index += 1
        }
        seq.insert(contentsOf: pinnedGroup, at: 0)
        for (i, name) in seq.enumerated() { positions[name] = gridPoint(index: i, columns: cols) }
    }

    private func compactGrid(_ positions: inout [String: CGPoint], width: CGFloat, pinned: [String] = []) {
        let cols = gridColumns(width: width)
        let seq = orderedNames(positions, pinned: pinned)
        for (i, name) in seq.enumerated() { positions[name] = gridPoint(index: i, columns: cols) }
    }

    private func moveItems(names: [String], from sourceID: UUID, to targetID: UUID, positions: [String: CGPoint]) {
        guard let source = store.frame(id: sourceID), let target = store.frame(id: targetID) else { return }

        // 同一个框内部挪动：插到落点格，其余图标顺延。
        if sourceID == targetID {
            guard let content = panelViews[sourceID] else { return }
            var frame = source
            let drop = positions[names.first ?? ""] ?? .zero
            insertGroup(names, atDrop: drop, into: &frame.positions, width: content.bounds.width,
                        pinned: frame.pinnedNames ?? [])
            store.update(frame)
            panelViews[sourceID]?.applyPositions(frame.positions)
            return
        }

        // 跨框：文件真实搬到目标托盘的子文件夹，插入落点格；源框由 syncFrame 压实补位。
        // 移动 I/O 放后台串行队列（大文件不冻结 UI）；执行前过结构闸门防托盘被关。
        let sourceFolder = store.folder(for: source)
        let targetFolder = store.folder(for: target)
        let epochs = captureEpochs([sourceID, targetID])
        fileIOQueue.async { [weak self] in
            guard let self, self.fileTaskValid(frameIDs: [sourceID, targetID], epochs: epochs) else { return }
            let store = self.store
            var movedNames: [String] = []
            var firstDrop: CGPoint?
            for name in names {
                let sourceURL = sourceFolder.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: sourceURL.path) else { continue }
                let destination = store.uniqueURL(for: name, in: targetFolder)
                do {
                    try FileManager.default.moveItem(at: sourceURL, to: destination)
                    let finalName = destination.lastPathComponent
                    if let point = positions[name], firstDrop == nil { firstDrop = point }
                    movedNames.append(finalName)
                } catch {
                    presentFileError(error, context: "跨托盘移动文件")
                }
            }
            guard !movedNames.isEmpty else {
                DispatchQueue.main.async { self.syncFrame(sourceID) }
                return
            }
            DispatchQueue.main.async {
                // 完成时重新取当前 frame 合并，绝不把入队时的旧快照整份写回——
                // 大文件移动期间用户可能已调整目标托盘的图标位置/置顶。
                guard var current = store.frame(id: targetID) else { return }
                if let content = self.panelViews[targetID] {
                    self.insertGroup(movedNames, atDrop: firstDrop ?? .zero, into: &current.positions,
                                     width: content.bounds.width, pinned: current.pinnedNames ?? [])
                    store.update(current)
                    self.panelViews[targetID]?.showToast("已移动到「\(current.title)」×\(movedNames.count)")
                }
                self.syncFrame(sourceID)
                self.syncFrame(targetID)
            }
        }
    }

    private func draggedOut(_ items: [FolderEntry], from frameID: UUID, at screenPoint: NSPoint, operation: NSDragOperation) {
        // Finder 是拖放目标，由它独自处理移动和同名冲突；源端绝不再搬一次。
        // Finder 的移动可能在拖拽会话结束后才完成，所以稍后按真实文件夹内容同步。
        guard let frame = store.frame(id: frameID) else { return }
        store.rememberDesktopDeparture(items, from: frameID,
                                       identities: activeGlassDragContext?.fileIdentities ?? [:])
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        let identities = Dictionary(uniqueKeysWithValues: items.compactMap { item -> (String, String)? in
            guard let identity = activeGlassDragContext?.fileIdentities[item.name] ??
                    FrameStore.fileIdentity(item.url) else { return nil }
            return (item.name, identity)
        })
        let grabbed = activeGlassDragContext?.grabbedName ?? items.first?.name ?? ""
        let anchor = frame.positions[grabbed] ?? .zero
        let screenTop = NSScreen.main?.frame.maxY ?? 0
        // Finder 负责实际移动；确认目标文件已出现后只调整桌面图标坐标，不再次移动文件。
        func placeAfterFinderMove(_ remaining: Int) {
            var desktopPositions: [String: CGPoint] = [:]
            for item in items {
                let url = desktop.appendingPathComponent(item.name)
                guard FrameStore.fileIdentity(url) == identities[item.name],
                      let point = frame.positions[item.name] else { continue }
                desktopPositions[item.name] = CGPoint(x: max(40, screenPoint.x + point.x - anchor.x),
                                                       y: max(40, screenTop - screenPoint.y + point.y - anchor.y))
            }
            if desktopPositions.count == items.count {
                FinderDesktop.setPositions(desktopPositions)
            } else if remaining > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    placeAfterFinderMove(remaining - 1)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { placeAfterFinderMove(8) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.syncFrame(frameID)
        }
    }

    private func captureEpochs(_ ids: [UUID]) -> [UUID: Int] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, store.epoch(for: $0)) })
    }

    private func returnItemsToDesktop(_ items: [FolderEntry], from frameID: UUID) {
        guard store.frame(id: frameID) != nil else { return }
        store.rememberDesktopDeparture(items, from: frameID)
        // 移回桌面可能涉及大文件/跨卷：I/O 放后台，完成后回主线程刷新。
        let epochs = captureEpochs([frameID])
        fileIOQueue.async { [weak self] in
            guard let self, self.fileTaskValid(frameIDs: [frameID], epochs: epochs) else { return }
            let store = self.store
            var done = 0
            for item in items where store.exportToDesktop(url: item.url) != nil { done += 1 }
            DispatchQueue.main.async {
                if done > 0 { self.panelViews[frameID]?.showToast("已移回桌面 ×\(done)") }
                self.syncFrame(frameID)
            }
        }
    }

    // MARK: Finder 式操作

    /// 把文件搬进托盘里的某个子文件夹（拖到文件夹图标上松手）。
    /// 移动语义与 importURL 一致：home 内同卷移动，外部来源拷贝。
    private func importIntoFolder(_ urls: [URL], folderName: String, frameID: UUID) {
        guard let frame = store.frame(id: frameID) else { return }
        let base = store.folder(for: frame).standardizedFileURL
        let target = base.appendingPathComponent(folderName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        // 大文件复制/移动可能耗时数秒：纯 I/O 放后台串行队列，完成后回主线程刷新。
        let epochs = captureEpochs([frameID])
        fileIOQueue.async { [weak self] in
            guard let self, self.fileTaskValid(frameIDs: [frameID], epochs: epochs) else { return }
            let store = self.store
            var done = 0
            for url in urls {
                let source = url.standardizedFileURL
                guard source.path != target.path, !target.path.hasPrefix(source.path + "/") else { continue }
                // 文件本来就在目标文件夹里：拖回自己所在的文件夹不该复制出「xxx (2)」副本。
                guard source.deletingLastPathComponent().path != target.path else { continue }
                let dest = store.uniqueURL(for: source.lastPathComponent, in: target)
                let shouldMove = source.path.hasPrefix(home + "/") &&
                    !source.path.hasPrefix(home + "/Library/")
                var ok = false
                do {
                    if shouldMove {
                        try FileManager.default.moveItem(at: source, to: dest)
                    } else {
                        try FileManager.default.copyItem(at: source, to: dest)
                    }
                    ok = true
                    done += 1
                } catch {
                    presentFileError(error, context: shouldMove ? "移动文件到文件夹" : "复制文件到文件夹")
                }
                dropLog("intoFolder \(shouldMove ? "move" : "copy") \(ok ? "ok" : "FAIL") \(source.lastPathComponent) -> \(folderName)")
            }
            DispatchQueue.main.async {
                if done > 0 { self.panelViews[frameID]?.showToast("已移入「\(folderName)」×\(done)") }
                self.syncFrame(frameID)
            }
        }
    }

    /// 拖拽兜底：会话以空操作结束（drop 被系统吞掉，如 tooltip 垫在光标下），
    /// 但松手点压在某个托盘的文件夹图标上——就地完成进文件夹。
    private func rescueCancelledDrop(at screenPoint: NSPoint, items: [FolderEntry], sourceFrameID: UUID) {
        guard !items.isEmpty else { return }
        let names = items.map(\.name)
        for (frameID, panel) in panelViews {
            guard let folderName = panel.dropFolderName(atScreenPoint: screenPoint) else { continue }
            // 只有同一块托盘内才需要剔除目标文件夹自身；跨托盘时按名字剔除会误伤同名文件。
            let movable = sourceFrameID == frameID ? names.filter { $0 != folderName } : names
            guard !movable.isEmpty else { return }
            dropLog("[rescue] \(movable.joined(separator: ",")) -> \(folderName)")
            moveItemsIntoFolder(movable, folderName: folderName,
                                sourceFrameID: sourceFrameID, targetFrameID: frameID)
            return
        }
    }

    /// 托盘内/跨托盘拖拽：把一组条目挪进某个托盘窗口里的文件夹图标。
    private func moveItemsIntoFolder(_ names: [String], folderName: String,
                                     sourceFrameID: UUID, targetFrameID: UUID) {
        guard let sourceFrame = store.frame(id: sourceFrameID),
              let targetFrame = store.frame(id: targetFrameID) else { return }
        let base = store.folder(for: sourceFrame).standardizedFileURL
        let target = store.folder(for: targetFrame).standardizedFileURL
            .appendingPathComponent(folderName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        // 移动可能涉及大文件：纯 I/O 放后台串行队列，完成后回主线程刷新两块托盘。
        let epochs = captureEpochs([sourceFrameID, targetFrameID])
        fileIOQueue.async { [weak self] in
            guard let self, self.fileTaskValid(frameIDs: [sourceFrameID, targetFrameID], epochs: epochs) else { return }
            let store = self.store
            var done = 0
            // 只有同一块托盘内才需要剔除目标文件夹自身；跨托盘时源列表里
            // 不可能含目标文件夹，按名字剔除会误伤恰好同名的文件。
            for name in names where !(sourceFrameID == targetFrameID && name == folderName) {
                let source = base.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                let dest = store.uniqueURL(for: name, in: target)
                do {
                    try FileManager.default.moveItem(at: source, to: dest)
                    done += 1
                    dropLog("trayIntoFolder move ok \(name) -> \(folderName)")
                } catch {
                    presentFileError(error, context: "移动到文件夹")
                    dropLog("trayIntoFolder move FAIL \(name) -> \(folderName)")
                }
            }
            DispatchQueue.main.async {
                if done > 0 { self.panelViews[targetFrameID]?.showToast("已移入「\(folderName)」×\(done)") }
                self.syncFrame(sourceFrameID)
                if sourceFrameID != targetFrameID { self.syncFrame(targetFrameID) }
            }
        }
    }

    private func renameItem(_ name: String, in frameID: UUID) {
        guard var frame = store.frame(id: frameID) else { return }
        NSApp.activate(ignoringOtherApps: true)
        guard let input = GlassDialog.prompt(title: "重新命名", text: name,
                                             confirmTitle: "保存") else { return }
        let newName = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, !newName.contains("/"), !newName.contains(":"),
              newName != name else { return }
        let folder = store.folder(for: frame)
        let source = folder.appendingPathComponent(name)
        let target = folder.appendingPathComponent(newName)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            GlassDialog.error(CocoaError(.fileWriteFileExists))
            return
        }
        do {
            try FileManager.default.moveItem(at: source, to: target)
            frame.positions[newName] = frame.positions.removeValue(forKey: name)
            if var pinned = frame.pinnedNames {
                pinned = pinned.map { $0 == name ? newName : $0 }
                frame.pinnedNames = pinned
            }
            store.update(frame)
            syncFrame(frameID)
        } catch {
            GlassDialog.error(error)
        }
    }

    private func duplicateItems(_ names: [String], in frameID: UUID) {
        guard let frame = store.frame(id: frameID) else { return }
        let folder = store.folder(for: frame)
        // 复制副本可能涉及大文件：纯 I/O 放后台串行队列，完成后回主线程刷新。
        let epochs = captureEpochs([frameID])
        fileIOQueue.async { [weak self] in
            guard let self, self.fileTaskValid(frameIDs: [frameID], epochs: epochs) else { return }
            let store = self.store
            var done = 0
            for name in names {
                let source = folder.appendingPathComponent(name)
                let target = store.uniqueURL(for: name, in: folder)
                do {
                    try FileManager.default.copyItem(at: source, to: target)
                    done += 1
                } catch {
                    // 后台队列里弹窗必须走 presentFileError（内部自动切主线程）。
                    presentFileError(error, context: "创建副本")
                }
            }
            DispatchQueue.main.async {
                if done > 0 { self.panelViews[frameID]?.showToast("已创建副本 ×\(done)") }
                self.syncFrame(frameID)
            }
        }
    }

    private func trashItems(names: [String], in frameID: UUID) {
        guard let frame = store.frame(id: frameID) else { return }
        let folder = store.folder(for: frame)
        let epochs = captureEpochs([frameID])
        fileIOQueue.async { [weak self] in
            guard let self, self.fileTaskValid(frameIDs: [frameID], epochs: epochs) else { return }
            let store = self.store
            var done = 0
            for name in names {
                if store.trashURL(folder.appendingPathComponent(name)) { done += 1 }
            }
            DispatchQueue.main.async {
                if done > 0 { self.panelViews[frameID]?.showToast("已移到废纸篓 ×\(done)") }
                self.syncFrame(frameID)
            }
        }
    }

    // 点进托盘时把 Finder 桌面的选中清空，托盘和桌面两边选中互斥。
    private func clearFinderDesktopSelection() {
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", "tell application \"Finder\" to set selection to {}"]
            try? task.run()
            task.waitUntilExit()
        }
    }

    private func createNewFolder(in frameID: UUID) {
        guard let frame = store.frame(id: frameID) else { return }
        // 前置检查：总目录和托盘子目录都必须真实存在且是目录。缺失时绝不隐式重建
        // （Finder 刚改名子目录时，补建旧名空目录会让真实目录失去托盘归属）。
        var isDir: ObjCBool = false
        let sub = store.folderURL(for: frame)
        guard FileManager.default.fileExists(atPath: store.rootDirectory.path, isDirectory: &isDir), isDir.boolValue,
              FileManager.default.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue else {
            presentFileError(CocoaError(.fileNoSuchFile),
                             context: "新建文件夹中止：托盘「\(frame.title)」的文件夹当前不可访问")
            return
        }
        let folder = sub
        var name = "未命名文件夹"
        var index = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "未命名文件夹 \(index)"
            index += 1
        }
        do {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(name),
                                                    withIntermediateDirectories: false)
        } catch {
            presentFileError(error, context: "新建文件夹")
        }
        syncFrame(frameID)
    }

    private func createNewTextDocument(in frameID: UUID) {
        guard let frame = store.frame(id: frameID) else { return }
        // 写文件前先确认目录真实存在且是文件夹：不隐式补建（Finder 刚改名子目录时，
        // 补建旧名空目录会让文档写进孤儿目录、托盘里看不见）。
        var isDir: ObjCBool = false
        let folder = store.folderURL(for: frame)
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir),
              isDir.boolValue else {
            presentFileError(CocoaError(.fileNoSuchFile),
                             context: "新建文本文件中止：托盘「\(frame.title)」的文件夹当前不可访问")
            return
        }
        var name = "未命名.txt"
        var index = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "未命名 \(index).txt"
            index += 1
        }
        let path = folder.appendingPathComponent(name).path
        let created = FileManager.default.createFile(atPath: path, contents: Data())
        if !created {
            presentFileError(CocoaError(.fileWriteUnknown), context: "新建文本文件")
        }
        syncFrame(frameID)
    }

    private func pasteInto(frameID: UUID) {
        guard let frame = store.frame(id: frameID) else { return }
        guard let urls = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else { return }
        // 复制大文件可能耗时：纯 I/O 放后台串行队列，完成后回主线程刷新。
        // 目标目录与总目录路径都在主线程预先确认，防换总目录进行中搬错位置。
        let epochs = captureEpochs([frameID])
        let targetFolder = store.folder(for: frame).standardizedFileURL
        let rootPath = store.rootDirectory.standardizedFileURL.path
        fileIOQueue.async { [weak self] in
            guard let self, self.fileTaskValid(frameIDs: [frameID], epochs: epochs) else { return }
            let store = self.store
            var done = 0
            for url in urls where store.copyURL(url, into: frame, targetFolderOverride: targetFolder,
                                                rootPathOverride: rootPath) != nil { done += 1 }
            DispatchQueue.main.async {
                if done > 0 { self.panelViews[frameID]?.showToast("已粘贴 ×\(done)") }
                self.syncFrame(frameID)
            }
        }
    }

    private func isDesktopPoint(_ point: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return false }
        // 桌面区域 = 屏幕去掉菜单栏和 Dock 后的可见范围。
        return screen.visibleFrame.contains(point)
    }

    // MARK: 总文件夹

    private func chooseRoot(firstRun: Bool = false) {
        NSApp.activate(ignoringOtherApps: true)
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.canCreateDirectories = true
        picker.allowsMultipleSelection = false
        picker.prompt = "用这个文件夹"
        picker.message = "选择托盘的总文件夹。每个托盘会在它里面开一个子文件夹。"
        picker.directoryURL = store.rootDirectory

        guard picker.runModal() == .OK, let chosen = picker.url else {
            if firstRun {
                // 取消也记住默认位置，避免每次启动都弹。
                store.rememberRootChoice()
            }
            return
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let forbidden = ["/", home, home + "/Desktop"]
        guard !forbidden.contains(chosen.standardizedFileURL.path) else {
            GlassDialog.info(title: "这个位置不能用",
                             message: "别选磁盘根目录、个人文件夹或桌面本身，会和托盘的收纳逻辑打架。")
            if firstRun { store.rememberRootChoice() }
            return
        }

        // 同路径重复选择：不 bump 版本、不进结构变更队列——否则排队的文件任务
        // 会被这次无效的「迁移」误杀，界面还没有任何失败提示。
        guard chosen.standardizedFileURL.path != store.rootDirectory.standardizedFileURL.path else {
            if firstRun { store.rememberRootChoice() }
            return
        }
        // 选了当前总目录的子目录：迁移等于把总文件夹搬进自己内部，changeRoot 必然
        // 拒绝——同样在 bump 版本前拦下，别让它白白发根版本、作废排队任务。
        guard !chosen.standardizedFileURL.path
            .hasPrefix(store.rootDirectory.standardizedFileURL.path + "/") else {
            GlassDialog.info(title: "这个位置不能用",
                             message: "不能把总文件夹移到它自己的子文件夹里。")
            if firstRun { store.rememberRootChoice() }
            return
        }

        // 迁移的可预检项提前到版本递增之前：任一托盘子目录缺失/不是文件夹时，
        // 这次迁移必然失败——不 bump root 版本，别让排队中的文件任务为一次
        // 注定失败的迁移陪葬（执行时 changeRoot 内部还会复检，防 TOCTOU 竞态）。
        for frame in store.frames {
            let sub = store.folderURL(for: frame)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: sub.path, isDirectory: &isDir),
                  isDir.boolValue else {
                GlassDialog.info(title: "无法更换总文件夹",
                                 message: "托盘「\(frame.title)」的子文件夹当前不存在或不可访问，迁移中止：\n\(sub.path)\n\n请先恢复该文件夹再试。")
                if firstRun { store.rememberRootChoice() }
                return
            }
        }

        // 换总目录是全局结构性变更：等在途文件任务全部结束再迁移，
        // 防止迁移期间后台任务把文件搬进旧路径/新路径的错位位置。
        let rootPathBefore = store.rootDirectory.standardizedFileURL.path
        performStructuralChange(bumpRoot: true) { [weak self] in
            guard let self else { return }
            switch self.store.changeRoot(to: chosen) {
            case .success:
                for frame in self.store.frames {
                    self.panelViews[frame.id]?.frameFolderURL = self.store.folder(for: frame)
                    self.syncFrame(frame.id)
                }
            case .failedClean where self.store.rootDirectory.standardizedFileURL.path == rootPathBefore:
                // 迁移执行失败但完整回滚，磁盘与记录和迁移前一致。root 版本已被推高：
                // bump 前排队、尚未过闸的任务被作废，但 bump 后新排队的任务会照常执行——
                // 不能断言「全部取消」，只提示可能取消、先核对再重试，防止重试出重复副本。
                GlassDialog.info(title: "更换总文件夹失败",
                                 message: "总文件夹没有变化。\n\n此前排队中的文件操作可能已被取消，也可能已照常完成；请先核对实际结果（比如有没有多出文件或副本），再决定要不要重试。")
            case .failedPartial(let failures):
                // 部分托盘文件夹留在新位置：旧路径虽在、文件已不在原处，
                // 让用户直接重试文件操作不合适，先处理位置再说。
                GlassDialog.info(title: "更换总文件夹失败",
                                 message: "部分托盘文件夹未能搬回原处，请先按下面的实际位置处理：\n"
                                    + failures.joined(separator: "\n")
                                    + "\n\n处理完之前不建议重试拖入、粘贴等文件操作。")
            case .failedClean:
                break // 罕见：回滚完成但根路径已变（如外部同时改动），交由常规同步收敛
            }
        }
    }
}

// MARK: - 入口

// 同一账户只允许一份托盘进程持有窗口，避免调试版与正式版叠出两套相同图标。
let lockDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("DesktopGlassFrame", isDirectory: true)
try? FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
let lockFD = open(lockDirectory.appendingPathComponent("active.lock").path, O_CREAT | O_RDWR, 0o600)
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    fputs("桌面托盘：已有实例在运行，本进程退出\n", stderr)
    exit(0)
}

CrashGuard.install()
let app = NSApplication.shared
let delegate = FrameApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

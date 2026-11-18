import AppKit
import Foundation
import ImageIO

/// [A-5] L1 纯函数自测 + L2 契约断言（HTML §22.11）。
///
/// 目的只有一个：**让逻辑 bug 在我们自己手里就现形**，而不是等用户点出来。
/// 这一层不看 UI、不读库、不联网，所以它能在任何环境跑：
///
///  - 命令行：`SpaceStation.app/Contents/MacOS/SpaceStation --self-check`
///    （打印每条结果，全绿退出码 0，有红退出码 1 → 可以接进脚本/CI）
///  - 应用内：诊断面板底部列出同一批结果
///
/// 规矩（写检查点的时候顺手就守住了边界）：
///  1. 只测**纯函数**（分类 / 净化 / 一级显示 / key / 降采样 / 名字回落）。
///     需要 NSView、需要真实剪贴板、需要用户点两下的，不塞进这里。
///  2. 每条必须能说清“失败意味着什么”。说不出就别加——噪音比没测更坏。
///  3. 加功能时先加一条用例，再写实现（先红后绿）。
enum SelfCheck {
    struct Item: Sendable, Identifiable {
        let id = UUID()
        let layer: String        // "L1" / "L2"
        let name: String
        let ok: Bool
        let detail: String
    }

    // MARK: - 汇总

    static func runAll() -> [Item] {
        classification() + purify() + oneLevel() + thumbnail() + resolver() + layout()
            + memoryTidy()
    }

    /// 命令行入口：打印 + 返回是否全绿。
    @discardableResult
    static func runAndPrint() -> Bool {
        let items = runAll()
        let failed = items.filter { !$0.ok }
        print("Space Station · 自检（L1 纯函数 / L2 契约）")
        for item in items {
            print("\(item.ok ? "PASS" : "FAIL")  [\(item.layer)] \(item.name) — \(item.detail)")
        }
        print("---- \(items.count - failed.count)/\(items.count) 通过")
        if !failed.isEmpty {
            print("失败项：" + failed.map(\.name).joined(separator: ", "))
        }
        return failed.isEmpty
    }

    // MARK: - ② 分类（ClipKind，纯函数）

    private static func classification() -> [Item] {
        [
            check("分类·链接", ClipKind.derive(types: ["public.utf8-plain-text"],
                                          text: "https://example.com/a?b=1") == .url),
            check("分类·代码", ClipKind.derive(types: ["public.utf8-plain-text"],
                                          text: "func foo() {\n    return 1\n}") == .code),
            check("分类·纯文本", ClipKind.derive(types: ["public.utf8-plain-text"],
                                           text: "今天下午三点开会") == .text),
            check("分类·图片优先于文字", ClipKind.derive(types: ["public.png", "public.utf8-plain-text"],
                                               text: "https://example.com") == .image),
            // 这条是「筛选项里视频永远为 0」的证据：复制 mp4 拿到的是 file-url，先归文件。
            check("分类·文件优先于文字", ClipKind.derive(types: ["public.file-url", "public.utf8-plain-text"],
                                               text: "https://example.com") == .file),
        ]
    }

    // MARK: - ⑩ 出站净化（LinkPurifier，纯函数）

    private static func purify() -> [Item] {
        let tracked = "https://shop.example.com/item?utm_source=weibo&utm_medium=social&id=42"
        let cleaned = LinkPurifier.purify(tracked)
        return [
            check("净化·去掉追踪参数", !cleaned.contains("utm_source") && !cleaned.contains("utm_medium"),
                  cleaned),
            check("净化·保留业务参数", cleaned.contains("id=42"), cleaned),
            check("净化·无链接原样返回", LinkPurifier.purify("就是一句话") == "就是一句话"),
        ]
    }

    // MARK: - 卡片一级显示（ClipKind.oneLevelDisplay）

    private static func oneLevel() -> [Item] {
        let long = "https://DJGoL.subxly.cfd:8443/api/v1/client/54a010a50b51d?x=1"
        let host = ClipKind.oneLevelDisplay(long)
        return [
            // 域名大小写不敏感，Foundation 会把 host 规范化成小写（Safari 地址栏也一样）。
            // 这是我们要的行为：同一个域名不会出现两种写法。
            check("一级显示·只留 host", host == "djgol.subxly.cfd", host ?? "nil"),
            check("一级显示·非链接返回 nil", ClipKind.oneLevelDisplay("普通文本") == nil),
        ]
    }

    // MARK: - ⑥ 图像管线（key 内容寻址 + 降采样不放大）

    private static func thumbnail() -> [Item] {
        var items: [Item] = []

        let a = Data(repeating: 0x01, count: 64)
        let b = Data(repeating: 0x02, count: 64)
        let keyA = ThumbnailCache.key(forData: a)
        items.append(check("缩略图 key·同内容同 key", keyA == ThumbnailCache.key(forData: a)))
        items.append(check("缩略图 key·异内容异 key", keyA != ThumbnailCache.key(forData: b)))

        // 小图不许被放大（曾把 366×780 放大成 1024 宽，卡片会糊）。
        if let small = makePNG(width: 400, height: 300),
           let out = ThumbnailCache.downsample(small, maxPixel: 1024) {
            items.append(check("降采样·小图不放大",
                               out.width == 400 && out.height == 300,
                               "\(out.width)×\(out.height) ← 400×300"))
        } else {
            items.append(check("降采样·小图不放大", false, "生成测试图失败"))
        }

        // 大图必须被压到长边 1024，且保持比例（这就是 8K 图不再吃 120MB 的关键）。
        if let big = makePNG(width: 4000, height: 2500),
           let out = ThumbnailCache.downsample(big, maxPixel: 1024) {
            let ratioOK = abs(Double(out.width) / Double(out.height) - 4000.0 / 2500.0) < 0.02
            items.append(check("降采样·长边封顶 1024",
                               out.width == 1024 && ratioOK,
                               "\(out.width)×\(out.height) ← 4000×2500"))
        } else {
            items.append(check("降采样·长边封顶 1024", false, "生成测试图失败"))
        }

        return items
    }

    // MARK: - ⑤ 来源解析回落（标题不出现整串 bundle id）

    private static func resolver() -> [Item] {
        let info = SourceAppResolver.resolve("com.example.notinstalled")
        return [
            check("来源解析·失败回落一级名", info.name == "notinstalled", info.name),
            check("来源解析·失败无图标", info.icon == nil),
        ]
    }

    // MARK: - 布局几何（卡比例随边反转 + 内容井填充裁决）

    /// 这两组规则一旦接反，用户看到的就是“手机截图在卡里只剩一条细缝”——
    /// 肉眼能发现，但只有写成用例才不会在下次改比例时又接反。
    private static func layout() -> [Item] {
        let top = EdgePosition.top.cardSize
        let bottom = EdgePosition.bottom.cardSize
        let left = EdgePosition.left.cardSize
        let right = EdgePosition.right.cardSize
        var items: [Item] = []

        // **开发基准轴**：验收只在一条边上做（用户 2026-11-18 定案）。
        // 四条边共用一套卡，但两边同时改 = 每轮开两次盲盒；出问题时分不清
        // 是改动错了，还是这条边本来不适用。所以基准必须是横向顶部，
        // 纵向的一切尺寸都从它推导，不许在纵向上单独调参。
        let baseline = EdgePosition.developmentBaseline
        items.append(check(
            "开发基准轴 = 顶部横向（纵向为派生）",
            baseline == .top && baseline.scrollsHorizontally,
            "\(baseline.cnLabel) · \(baseline.scrollsHorizontally ? "横向" : "纵向")"
        ))

        // **哪边是瓶颈就压哪边**（用户 2026-11-18 最终口径）：
        //   顶/底 = 横向排 → 宽度是瓶颈 → 压窄 → 3:4 竖版
        //   左/右 = 纵向排 → 高度是瓶颈 → 压矮 → 4:3 横版
        // 上一版把这条接反过一次，两边都在"抽屉里翻东西"，所以钉进 L1。
        items.append(check(
            "卡比例·顶/底为 3:4 竖版（压窄才装得下 5 张）",
            top.height > top.width && abs(top.width / top.height - 3.0 / 4.0) < 0.01
                && bottom == top,
            "\(Int(top.width))×\(Int(top.height))"
        ))
        items.append(check(
            "卡比例·左/右为 4:3 横版（压矮才装得下 5 张）",
            left.width > left.height && abs(left.width / left.height - 4.0 / 3.0) < 0.01
                && right == left,
            "\(Int(left.width))×\(Int(left.height))"
        ))

        // **图片卡：厚度固定，另一维跟着内容比例走；只有撞闸门才收。**
        // 这条取代了“clamp 比例 + cover 硬裁”，后者会把手机截图裁成局部特写。
        let phoneCard = EdgePosition.top.cardSize(imageAspect: 9.0 / 19.5)
        let wideShot = EdgePosition.top.cardSize(imageAspect: 16.0 / 10.0)
        let thinStrip = EdgePosition.top.cardSize(imageAspect: 680.0 / 2000.0)
        let phoneCardSide = EdgePosition.left.cardSize(imageAspect: 9.0 / 19.5)

        // 核心判据：**常见比例一个点都不裁**。卡形状就是内容形状，fit 天然贴合。
        // 只要这条成立，“局部特写”就不可能再出现——不是靠参数，是靠顺序。
        let commonAspects: [(String, CGSize)] = [
            ("1:1", CGSize(width: 1000, height: 1000)),
            ("3:4", CGSize(width: 900, height: 1200)),
            ("4:3", CGSize(width: 1600, height: 1200)),
            ("9:19.5", CGSize(width: 900, height: 1950)),
        ]
        let worstGutter = commonAspects.map { _, px -> Double in
            let card = EdgePosition.top.cardSize(imageAspect: px.width / px.height)
            return ContentWellFill.letterboxRatio(image: px, well: card)
        }.max() ?? 0
        items.append(check(
            "图片卡·常见比例零留白（卡跟着内容变形，不裁也不留缝）",
            worstGutter <= 0.02,
            String(format: "最坏留白 %.1f%%", worstGutter * 100)
        ))

        items.append(check(
            "图片卡·厚度恒定（横排锁高 120，不论图多宽多窄）",
            abs(phoneCard.height - 120) < 0.01 && abs(wideShot.height - 120) < 0.01
                && abs(thinStrip.height - 120) < 0.01,
            "9:19.5 → \(Int(phoneCard.width))×120 ｜ 16:10 → \(Int(wideShot.width))×120"
        ))
        items.append(check(
            "图片卡·极端比例撞最小边 52 而不是被压成缝",
            thinStrip.width >= StationMetrics.cardMinSide - 0.01
                && thinStrip.width < phoneCard.width,
            "680×2000 → \(Int(thinStrip.width))×120"
        ))
        items.append(check(
            "图片卡·宽卡撞上限不超过 1.5 倍厚度",
            wideShot.width <= 120 * StationMetrics.cardMaxStretch + 0.01,
            "\(Int(wideShot.width)) ≤ \(Int(120 * StationMetrics.cardMaxStretch))"
        ))
        // 纵向：宽度锁 120（瓶颈是高度），高度跟着比例走。
        items.append(check(
            "图片卡·纵向锁宽 120（一列装得下 5 张）",
            abs(phoneCardSide.width - 120) < 0.01,
            "\(Int(phoneCardSide.width))×\(Int(phoneCardSide.height))"
        ))

        // **一屏 5 张**是产品硬指标，不是形容词。
        // 面板尺寸由卡尺寸反推，所以这里直接量“面板里究竟塞得下几张”——
        // 谁把卡改大、间距改宽，这条当场变红。
        // 横向是主判据；纵向只验「派生出来还能不能装下 5 张」。
        for (edge, name) in [(EdgePosition.top, "基准轴·顶/底"), (.left, "派生·左/右")] {
            let capacity = edge.firstScreenCapacity
            let panel = edge.panelSize
            items.append(check(
                "首屏·\(name)装得下 \(StationMetrics.firstScreenCards) 张",
                capacity >= StationMetrics.firstScreenCards,
                "\(capacity) 张 / 面板 \(Int(panel.width))×\(Int(panel.height))"
            ))
        }

        // 填充方式：**fit**。前提是卡形状已经贴合内容（上面的零留白断言保证了这点）。
        // 谁把它改回 cover，等于把“先定死形状再塞图”的老路重走一遍，这条当场变红。
        items.append(check(
            "内容井·填充方式固定 fit（卡已贴合，禁止回退 cover）",
            ContentWellFill.contentMode == .fit,
            "\(ContentWellFill.contentMode)"
        ))
        items.append(check(
            "内容井·锚点居中（撞闸门时两侧留白对称）",
            ContentWellFill.alignment == .center,
            "\(ContentWellFill.alignment)"
        ))
        // 撞闸门的极端图，留白必须有上限，否则“一条缝”会从后门回来。
        let extremeGutter = ContentWellFill.letterboxRatio(
            image: CGSize(width: 680, height: 2000),
            well: thinStrip
        )
        items.append(check(
            "内容井·极端比例留白 ≤ 35%（细长图不变成一根针）",
            extremeGutter <= 0.35,
            String(format: "%.0f%%", extremeGutter * 100)
        ))


        // 图标标尺：源 App 16、动作图标 14（外框 16，差 2 是给描边留的视觉补偿）。
        items.append(check(
            "图标标尺·源 16 / 动作 14",
            StationMetrics.glyphSize == 16 && StationMetrics.actionGlyphSize == 14
                && StationMetrics.actionChipSize == 16,
            "\(Int(StationMetrics.glyphSize)) / \(Int(StationMetrics.actionGlyphSize))"
        ))

        // **单实例闸门**。2026-11-18 实测事故：任务栏真出现了两个图标，
        // 两个实例同时监听 NSPasteboard，历史会重复写入。
        // 当时只有一条「进程唯一性」的**检查**，没有任何**阻止**。
        // 现在两道闸门，这条断言钉住第一道（Info.plist），
        // 第二道（SingleInstanceGuard）由启动路径保证，改坏了会立刻暴露成两个图标。
        let singleInstanceFlag = Bundle.main.object(forInfoDictionaryKey: "LSMultipleInstancesProhibited")
        items.append(check(
            "单实例·Info.plist 带 LSMultipleInstancesProhibited",
            (singleInstanceFlag as? Bool) == true,
            "\(singleInstanceFlag ?? "缺失")"
        ))

        // **接管的判定规则**（`SingleInstanceGuard.decide`，纯函数）。
        // 用户原话：「按照先后顺序杀死那个之前的进程……万一他连续双击打开，他可能就卡死了。」
        // 第一版做反了：旧实例留着、新进程退出 —— 结果改完编译启动，看到的还是上一版。
        let t0 = Date(timeIntervalSince1970: 1_000)
        let t1 = Date(timeIntervalSince1970: 2_000)
        let mine = SingleInstanceGuard.Instance(pid: 100, path: "/A/SpaceStation", builtAt: t1, launchedAt: t1)
        let sameBuildOlderLaunch = SingleInstanceGuard.Instance(
            pid: 90, path: "/A/SpaceStation", builtAt: t1, launchedAt: t0
        )
        items.append(check(
            "单实例·同一份二进制，杀旧进程由新进程接管",
            SingleInstanceGuard.decide(mine: mine, others: [sameBuildOlderLaunch]) == .takeOver(stale: [90]),
            "旧 pid 90 → 除")
        )
        let staleBuild = SingleInstanceGuard.Instance(
            pid: 80, path: "/old/SpaceStation", builtAt: t0, launchedAt: t0
        )
        items.append(check(
            "单实例·旧构建的拷贝（不同路径）也被接管",
            SingleInstanceGuard.decide(mine: mine, others: [staleBuild]) == .takeOver(stale: [80]),
            "旧构建 \(staleBuild.path) → 除")
        )
        let newerBuild = SingleInstanceGuard.Instance(
            pid: 110, path: "/new/SpaceStation", builtAt: t1.addingTimeInterval(600), launchedAt: t0
        )
        items.append(check(
            "单实例·已在跑的包更新时，本包让位（不用旧包杀新包）",
            SingleInstanceGuard.decide(mine: mine, others: [newerBuild]) == .yieldTo(pid: 110),
            "对方更新 → 本进程退出")
        )
        items.append(check(
            "单实例·SIGTERM 宽限 2 秒后才 SIGKILL（卡死兜底）",
            SingleInstanceGuard.graceSeconds == 2.0,
            String(format: "%.1fs", SingleInstanceGuard.graceSeconds)
        ))

        return items
    }

    // MARK: - 收起后的内存整理：频率闸（MemoryTidy.shouldRun，纯函数）

    /// 频率定错了会两头难受：太频繁 = 每次打开都重新解码、费电；太稀疏 = 常驻白占。
    /// 所以把这四条钉死，改数值前先跑一遍。
    private static func memoryTidy() -> [Item] {
        let now = 1_000_000.0
        let interval = MemoryTidy.minimumInterval
        var items: [Item] = []

        items.append(check(
            "内存整理·从未跑过 → 允许",
            MemoryTidy.shouldRun(lastRunAt: 0, now: now, lowPowerMode: false)
        ))
        items.append(check(
            "内存整理·299s 前跑过 → 跳过",
            !MemoryTidy.shouldRun(lastRunAt: now - 299, now: now, lowPowerMode: false)
        ))
        items.append(check(
            "内存整理·301s 前跑过 → 允许",
            MemoryTidy.shouldRun(lastRunAt: now - 301, now: now, lowPowerMode: false)
        ))
        items.append(check(
            "内存整理·低电量模式 → 一律跳过",
            !MemoryTidy.shouldRun(lastRunAt: 0, now: now, lowPowerMode: true)
                && !MemoryTidy.shouldRun(lastRunAt: now - 3600, now: now, lowPowerMode: true)
        ))
        items.append(check(
            "内存整理·间隔 = 300s",
            interval == 300,
            "\(Int(interval))s"
        ))

        return items
    }

    // MARK: - 工具

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "ok") -> Item {
        Item(layer: "L1", name: name, ok: ok, detail: detail)
    }

    /// 造一张纯色 PNG 当测试素材（不落盘，只要 Data）。
    private static func makePNG(width: Int, height: Int) -> Data? {
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(NSColor.systemTeal.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = ctx.makeImage() else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, "public.png" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

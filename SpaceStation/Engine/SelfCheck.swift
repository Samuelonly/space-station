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
        classification() + purify() + oneLevel() + thumbnail() + resolver()
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

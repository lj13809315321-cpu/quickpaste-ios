import UIKit

/// 剪贴板条目卡片：可滑动 + 长按菜单（对齐参考 App 的交互，用户 6 张截图）：
///   · 右滑 → 左边露出「分词」「预览」
///   · 左滑 → 右边露出「编辑」「删除」
///   · 继续使劲左滑 → 删除键放大铺满整条，松手直接删除
///   · 轻点 → 插入到输入框；长按 → 弹出操作菜单
///
/// 为什么自己写而不是用 UITableView 的 swipeActions：
/// 键盘里的列表是 UIStackView + UIScrollView（要和计算器、底行按键共处一屏），
/// 没有 UITableView 的行复用；这里用 frame 布局的轻量容器实现同样的手感。
final class QPSwipeCard: UIView {

    enum Action {
        case segment, preview, edit, delete
    }

    var onTap: (() -> Void)?
    var onLongPress: (() -> Void)?
    var onAction: ((Action) -> Void)?
    /// 滑开时通知列表把别的卡片归位
    var onOpen: (() -> Void)?
    /// 手指在卡片上操作中（滑动/长按）→ 列表先别重建，否则手势会被打断
    var onBusyChange: ((Bool) -> Void)?
    /// 横向滑动时把列表滚动关掉，避免 ScrollView 抢方向；松手恢复
    var onHorizontalSwipe: ((Bool) -> Void)?

    private let content: UIView
    private let actionW: CGFloat = 58
    private var offset: CGFloat = 0
    private var startOffset: CGFloat = 0
    /// 本次拖动是否已判定为横向滑动（竖着拖要留给列表滚动）
    private var horizontal = false
    private var armedHaptic = false
    private(set) var isBusy = false

    private let editBtn = QPSwipeCard.makeButton("编辑", UIColor(red: 124/255, green: 134/255, blue: 154/255, alpha: 1))
    private let deleteBtn = QPSwipeCard.makeButton("删除", QPColor.red)
    private let segmentBtn = QPSwipeCard.makeButton("分词", QPColor.blue)
    private let previewBtn = QPSwipeCard.makeButton("预览", UIColor(red: 124/255, green: 134/255, blue: 154/255, alpha: 1))

    init(content: UIView, height: CGFloat = 52) {
        self.content = content
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = true
        layer.cornerRadius = 12
        backgroundColor = QPColor.sep
        heightAnchor.constraint(equalToConstant: height).isActive = true

        // 动作按钮铺在底层，卡片盖在上面；滑开时露出来的部分才可见
        for b in [segmentBtn, previewBtn, editBtn, deleteBtn] {
            b.isHidden = true
            addSubview(b)
        }
        segmentBtn.addAction(UIAction { [weak self] _ in self?.fire(.segment) }, for: .touchUpInside)
        previewBtn.addAction(UIAction { [weak self] _ in self?.fire(.preview) }, for: .touchUpInside)
        editBtn.addAction(UIAction { [weak self] _ in self?.fire(.edit) }, for: .touchUpInside)
        deleteBtn.addAction(UIAction { [weak self] _ in self?.fire(.delete) }, for: .touchUpInside)

        addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = true

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        // 手指按在内容上也要能被识别（内容里的按钮自己处理点击）
        pan.cancelsTouchesInView = false
        addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.delegate = self
        addGestureRecognizer(tap)

        let long = UILongPressGestureRecognizer(target: self, action: #selector(handleLong(_:)))
        // 0.4s + 允许 14pt 抖动：手指稍微动一点不算滑走，长按照样弹菜单
        long.minimumPressDuration = 0.4
        long.allowableMovement = 14
        long.cancelsTouchesInView = false
        long.delegate = self
        addGestureRecognizer(long)

        // v1.8.15 修复：长按弹菜单后松手，系统仍会把这次手势识别成「轻点」从而
        // 把卡片内容插入输入栏。让 tap 必须等 long 失败才触发 —— 长按一旦开始，
        // 松手绝不会再走 onTap 插入；只有没触发长按的纯轻点才插入。
        tap.require(toFail: long)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 布局

    override func layoutSubviews() {
        super.layoutSubviews()
        applyLayout()
    }

    private func applyLayout() {
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0 else { return }

        content.frame = CGRect(x: offset, y: 0, width: w, height: h)

        let revealed = max(0, -offset)
        // 使劲左滑：删除键放大到铺满整条（截图 5 的效果）
        if revealed > actionW * 2 + 6 {
            let dw = min(revealed, w)
            deleteBtn.isHidden = false
            deleteBtn.frame = CGRect(x: w - dw, y: 0, width: dw, height: h)
            editBtn.isHidden = true
        } else {
            deleteBtn.isHidden = revealed < 2
            deleteBtn.frame = CGRect(x: w - actionW, y: 0, width: actionW, height: h)
            editBtn.isHidden = revealed < actionW
            editBtn.frame = CGRect(x: w - actionW * 2, y: 0, width: actionW, height: h)
        }
        segmentBtn.isHidden = offset < 2
        segmentBtn.frame = CGRect(x: 0, y: 0, width: actionW, height: h)
        previewBtn.isHidden = offset < actionW
        previewBtn.frame = CGRect(x: actionW, y: 0, width: actionW, height: h)
    }

    private func setOffset(_ x: CGFloat, animated: Bool, duration: TimeInterval = 0.22,
                           completion: (() -> Void)? = nil) {
        offset = x
        if animated {
            UIView.animate(withDuration: duration, delay: 0,
                           options: [.curveEaseOut],
                           animations: { self.applyLayout() },
                           completion: { _ in completion?() })
        } else {
            applyLayout()
            completion?()
        }
    }

    /// 别的卡片滑开时，这张要自动归位
    func close(animated: Bool = true) {
        guard offset != 0 else { return }
        setOffset(0, animated: animated)
    }

    var isOpen: Bool { abs(offset) > 1 }

    // MARK: - 手势

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let w = bounds.width
        switch g.state {
        case .began:
            startOffset = offset
            horizontal = offset != 0
            armedHaptic = false
            setBusy(true)
            if horizontal { onHorizontalSwipe?(true) }
        case .changed:
            let t = g.translation(in: self)
            if !horizontal {
                // 竖着拖是滚列表，不抢手势；只有横向才接管
                guard abs(t.x) > 6, abs(t.x) > abs(t.y) * 1.2 else { return }
                horizontal = true
                onHorizontalSwipe?(true)
            }
            var x = startOffset + t.x
            if x > 0 { x = min(x, actionW * 2 + 12) }
            if x < 0 { x = max(x, -w * 0.88) }
            setOffset(x, animated: false)

            let armed = -offset > actionW * 2 + 24
            if armed != armedHaptic {
                armedHaptic = armed
                if armed { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
            }
        case .ended, .cancelled, .failed:
            // busy 由 touchesBegan/Ended 统一收口，手势结束时不提前放开
            onHorizontalSwipe?(false)
            guard horizontal else { return }
            horizontal = false
            let v = g.velocity(in: self).x
            // 过阈值再往左甩 → 整条滑出后直接删除
            if -offset > actionW * 2 + 24 || (-offset > actionW * 1.5 && v < -900) {
                setOffset(-w, animated: true, duration: 0.18) { [weak self] in
                    guard let self = self else { return }
                    // 先删（本机删除会同步重建列表，这张卡片随即被移除），再复位
                    self.onAction?(.delete)
                    self.offset = 0
                    self.applyLayout()
                }
                return
            }
            if offset < 0 {
                setOffset(offset < -actionW * 0.6 ? -actionW * 2 : 0, animated: true)
            } else {
                setOffset(offset > actionW * 0.6 ? actionW * 2 : 0, animated: true)
            }
            if isOpen { onOpen?() }
        default:
            break
        }
    }

    @objc private func handleTap() {
        if isOpen {
            setOffset(0, animated: true)
        } else {
            onTap?()
        }
    }

    @objc private func handleLong(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            setBusy(true)
            if isOpen { setOffset(0, animated: true); return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onLongPress?()
        case .ended, .cancelled, .failed:
            break
        default:
            break
        }
    }

    // MARK: - 手指按下到抬起全程标记为「交互中」
    // 长按识别需要 0.4 秒；这期间任何 refreshList 都会把正在被按住的卡片
    // 从列表里销毁，手势被系统取消，表现为「随便长按一条都不弹菜单」。
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        setBusy(true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        setBusy(false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        setBusy(false)
    }

    private func setBusy(_ v: Bool) {
        guard isBusy != v else { return }
        isBusy = v
        onBusyChange?(v)
    }

    private func fire(_ action: Action) {
        setOffset(0, animated: false)
        onAction?(action)
    }

    // MARK: - 工具

    private static func makeButton(_ title: String, _ color: UIColor) -> UIButton {
        let b = QPHapticButton(type: .custom)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        b.setTitleColor(.white, for: .normal)
        b.backgroundColor = color
        b.translatesAutoresizingMaskIntoConstraints = true
        b.isHidden = true
        return b
    }
}

extension QPSwipeCard: UIGestureRecognizerDelegate {

    /// 点动作按钮时不要触发「轻点插入」
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        guard let v = touch.view else { return true }
        if v is UIButton, v !== content { return false }
        return true
    }

    /// 横向滑动与列表竖向滚动共存，方向由 handlePan 里的判定决定
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

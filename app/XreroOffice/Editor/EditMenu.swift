import UIKit

/// The native edit menu at a touch selection (plan S5, phase 1: text in Word): Cut, Copy, Paste, Select All, and Bold /
/// Italic when text is selected - the capsule every iPhone app shows, in the app's language and mirrored in Arabic,
/// readable by VoiceOver, with 44 pt rows. It replaces the editors' desktop right-click menu, which a long press used
/// to open on touch (web/xr-host.js "native edit menu" swallows that one and sends an 'editmenu' command instead).
///
/// How it is shown: a UIEditMenuInteraction on a transparent anchor view laid over the web view - not on the
/// WKWebView, which owns edit-menu interactions of its own. The anchor passes every touch through (hitTest nil) and
/// never becomes first responder, so the web view keeps the keyboard and the engine its caret. Public API only.
///
/// Each action is one EditorController.call into the editor frame (__xrEditMenu), on the tap only. Paste goes the
/// same way as the ribbon's Paste: the app reads UIPasteboard on that tap (iOS may ask "Allow Paste" for text copied
/// in another app; the prompt-free UIPasteControl cannot live inside an edit menu).
///
/// Flag: UserDefaults "xr.editMenu" (default ON). NO = the desktop right-click menu on touch, as before (the plan
/// keeps it reachable until the touch gate and the bug map have passed on devices). Pointer input (trackpad or mouse
/// on iPad / Mac) always keeps the desktop menu: xr-host.js only takes the long-press right click.
enum EditMenu {
    static let flagKey = "xr.editMenu"
    /// Unset = on. object(forKey:) is nil when unset; bool(forKey:) also reads the launch-argument form ("NO").
    static var enabled: Bool { UserDefaults.standard.object(forKey: flagKey) == nil || UserDefaults.standard.bool(forKey: flagKey) }

    /// What xr-host.js sends with 'editmenu': where (web view points) and what is selected there.
    struct Request {
        var rect: CGRect
        var type: String          // EditorState selection kinds: text, table, image, ...
        var selected: Bool        // something is selected (else just a caret)

        init?(_ json: String) {
            guard let d = json.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let x = (o["x"] as? NSNumber)?.doubleValue, let y = (o["y"] as? NSNumber)?.doubleValue else { return nil }
            let w = (o["w"] as? NSNumber)?.doubleValue ?? 2, h = (o["h"] as? NSNumber)?.doubleValue ?? 24
            rect = CGRect(x: x, y: y, width: max(w, 2), height: max(h, 2))
            type = o["type"] as? String ?? "none"
            selected = (o["sel"] as? Bool) ?? false
        }
    }
}

/// The transparent view the edit menu is presented from (one per editor web view, see XRWebView.editMenuAnchor).
final class EditMenuAnchor: UIView, UIEditMenuInteractionDelegate {
    private lazy var interaction = UIEditMenuInteraction(delegate: self)
    private var target = CGRect.zero
    private var request: EditMenu.Request?
    /// Runs one action ("cut", "copy", "paste", "selectall", "bold", "italic"); set by the web view's coordinator.
    var perform: ((String) -> Void)?
    /// Called each time iOS really presents the menu (the touch-gate probe counts it).
    var onPresent: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        addInteraction(interaction)
        accessibilityIdentifier = "xr-edit-menu-anchor"
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { nil }

    /// Every touch goes to the web view underneath: the anchor is only a place to present the menu from.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    func present(_ r: EditMenu.Request) {
        request = r
        target = r.rect.intersection(bounds.insetBy(dx: -1, dy: -1))
        if target.isNull || target.isEmpty { target = r.rect }
        // Arabic: the capsule's order mirrors with the app (UIKit reads the presenting view's direction)
        semanticContentAttribute = L.ar ? .forceRightToLeft : .forceLeftToRight
        interaction.dismissMenu()
        let config = UIEditMenuConfiguration(identifier: "xr-edit-menu", sourcePoint: CGPoint(x: target.midX, y: target.minY))
        interaction.presentEditMenu(with: config)
    }

    func dismiss() { interaction.dismissMenu() }

    // MARK: UIEditMenuInteractionDelegate

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        // only the app's own actions: the suggested ones would go to the responder chain (WebKit's hidden input field)
        guard let r = request else { return nil }
        var items: [UIMenuElement] = []
        func item(_ title: String, _ symbol: String, _ id: String) -> UIAction {
            UIAction(title: title, image: UIImage(systemName: symbol), identifier: UIAction.Identifier("xr-edit-menu-" + id)) { [weak self] _ in
                self?.perform?(id)
            }
        }
        if r.selected {
            items.append(item(L.cut, "scissors", "cut"))
            items.append(item(L.copy, "doc.on.doc", "copy"))
        }
        items.append(item(L.paste, "doc.on.clipboard", "paste"))
        items.append(item(L.selectAll, "selection.pin.in.out", "selectall"))
        if r.selected && r.type == "text" {
            items.append(item(L.bold, "bold", "bold"))
            items.append(item(L.italic, "italic", "italic"))
        }
        return UIMenu(children: items)
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        target
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willPresentMenuFor configuration: UIEditMenuConfiguration,
                             animator: any UIEditMenuInteractionAnimating) {
        onPresent?()
    }
}

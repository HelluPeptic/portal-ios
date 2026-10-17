import UIKit

/// A small card at the bottom of the screen: "Portal needs a refresh in
/// SideStore" or "A new version is ready", with one button and a close.
final class StatusBanner: UIView {
    var onAction: (() -> Void)?
    var onClose: (() -> Void)?

    private let label = UILabel()
    private let actionButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .portalElevated
        layer.cornerRadius = 14
        layer.borderWidth = 1
        layer.borderColor = UIColor.portalBorder.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.45
        layer.shadowRadius = 16
        layer.shadowOffset = CGSize(width: 0, height: 6)

        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .portalText
        label.numberOfLines = 0

        actionButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        actionButton.setTitleColor(.portalAccent, for: .normal)
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        actionButton.addAction(UIAction { [weak self] _ in self?.onAction?() }, for: .touchUpInside)

        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)), for: .normal)
        closeButton.tintColor = .portalTextDim
        closeButton.accessibilityLabel = "Close"
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)

        let row = UIStackView(arrangedSubviews: [label, actionButton, closeButton])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(text: String, button: String) {
        label.text = text
        actionButton.setTitle(button, for: .normal)
    }
}

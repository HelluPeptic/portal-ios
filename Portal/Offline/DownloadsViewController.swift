import UIKit

/// The Downloads list: what's saved on the phone, and what's on its way.
/// Tap one to watch it; ⋯ has its subtitles and removing it. Opened from
/// the Vault (its download button), or from the "Can't reach the site"
/// screen, which is where it's needed most.
final class DownloadsViewController: UITableViewController {
    private var rows: [OfflineItem] = []
    private var shownStates: [String] = []
    private let posters = NSCache<NSString, UIImage>()

    init() {
        super.init(style: .insetGrouped)
        title = "Downloads"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// In a sheet of its own, dark like the site.
    static func inSheet() -> UINavigationController {
        let nav = UINavigationController(rootViewController: DownloadsViewController())
        nav.overrideUserInterfaceStyle = .dark
        nav.navigationBar.tintColor = .portalAccent
        nav.view.tintColor = .portalAccent
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        return nav
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        tableView.backgroundColor = .portalBackground
        tableView.register(DownloadCell.self, forCellReuseIdentifier: "download")
        tableView.rowHeight = 96
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged), name: .offlineChanged, object: nil)
        reload()
    }

    @objc private func storeChanged() {
        let fresh = OfflineStore.shared.items.sorted { $0.addedAt > $1.addedAt }
        // Only progress moved: the rows are updated where they are, so an
        // open ⋯ menu stays open.
        if fresh.map(\.id) == rows.map(\.id) && fresh.map(Self.look) == shownStates {
            rows = fresh
            for case let cell as DownloadCell in tableView.visibleCells {
                guard let path = tableView.indexPath(for: cell), path.row < rows.count else { continue }
                cell.showProgress(rows[path.row])
                cell.showPoster(poster(rows[path.row]), kind: rows[path.row].kind)
            }
            updateFooter()
            return
        }
        reload()
    }

    /// What a row's ⋯ menu shows, besides progress.
    private static func look(_ entry: OfflineItem) -> String {
        "\(entry.state.rawValue) \(entry.subtitle ?? -1)"
    }

    private func reload() {
        rows = OfflineStore.shared.items.sorted { $0.addedAt > $1.addedAt }
        shownStates = rows.map(Self.look)
        tableView.reloadData()
        if rows.isEmpty {
            let empty = UILabel()
            empty.text = "Nothing here yet.\n\nIn the Vault, tap ⋯ on a movie or an episode, then Download. It downloads with the app closed too, and plays here without a connection."
            empty.numberOfLines = 0
            empty.textAlignment = .center
            empty.textColor = .portalTextDim
            empty.font = .systemFont(ofSize: 15)
            let holder = UIView()
            empty.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.centerYAnchor.constraint(equalTo: holder.centerYAnchor, constant: -40),
                empty.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 40),
                empty.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -40)
            ])
            tableView.backgroundView = holder
        } else {
            tableView.backgroundView = nil
        }
        updateFooter()
    }

    private func updateFooter() {
        guard let free = OfflineStore.shared.freeSpace, !rows.isEmpty else {
            tableView.tableFooterView = nil
            return
        }
        let text = "\(OfflineStore.format(free)) free on this \(UIDevice.current.model)"
        if let label = tableView.tableFooterView as? UILabel {
            if label.text != text { label.text = text }
            return
        }
        let label = UILabel(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 44))
        label.text = text
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 13)
        label.textColor = .portalTextDim
        tableView.tableFooterView = label
    }

    // MARK: - Rows

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "download", for: indexPath) as! DownloadCell
        let entry = rows[indexPath.row]
        cell.show(entry, poster: poster(entry))
        cell.moreButton.menu = menu(for: entry)
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let entry = rows[indexPath.row]
        switch entry.state {
        case .done:
            OfflinePlayback.play(entry.item, from: self)
        case .paused, .failed:
            OfflineStore.shared.retry(entry.item)
        case .downloading:
            break
        }
    }

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let entry = rows[indexPath.row]
        let remove = UIContextualAction(style: .destructive, title: "Remove") { _, _, done in
            OfflineStore.shared.remove(entry.item)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [remove])
    }

    private func menu(for entry: OfflineItem) -> UIMenu {
        var children: [UIMenuElement] = []
        if !entry.subtitles.isEmpty {
            var choices = [UIAction(title: "Off", state: entry.subtitle == nil ? .on : .off) { _ in
                OfflineStore.shared.setSubtitle(entry.item, nil)
            }]
            for (index, sub) in entry.subtitles.enumerated() {
                choices.append(UIAction(title: sub.label, state: entry.subtitle == index ? .on : .off) { _ in
                    OfflineStore.shared.setSubtitle(entry.item, index)
                })
            }
            children.append(UIMenu(title: "Subtitles", image: UIImage(systemName: "captions.bubble"), options: .displayInline, children: choices))
        }
        let removeTitle = entry.state == .done ? "Remove download" : "Stop and remove"
        children.append(UIAction(title: removeTitle, image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.confirmRemove(entry)
        })
        return UIMenu(title: entry.title, children: children)
    }

    private func confirmRemove(_ entry: OfflineItem) {
        let alert = UIAlertController(title: nil, message: "Remove \(entry.title) from this \(UIDevice.current.model)? It stays in the Vault.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { _ in OfflineStore.shared.remove(entry.item) })
        present(alert, animated: true)
    }

    private func poster(_ entry: OfflineItem) -> UIImage? {
        if let cached = posters.object(forKey: entry.id as NSString) { return cached }
        guard let image = UIImage(contentsOfFile: OfflineStore.shared.posterFile(entry).path) else { return nil }
        posters.setObject(image, forKey: entry.id as NSString)
        return image
    }
}

private final class DownloadCell: UITableViewCell {
    private let posterView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let statusLabel = UILabel()
    private let bar = UIProgressView(progressViewStyle: .default)
    let moreButton = UIButton(type: .system)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .portalElevated
        let selected = UIView()
        selected.backgroundColor = .portalBorder
        selectedBackgroundView = selected

        posterView.contentMode = .scaleAspectFill
        posterView.clipsToBounds = true
        posterView.layer.cornerRadius = 6
        posterView.backgroundColor = .portalBorder
        posterView.tintColor = .portalTextDim

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .portalText
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .portalTextDim
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .portalTextDim
        statusLabel.numberOfLines = 2
        bar.progressTintColor = .portalAccent
        bar.trackTintColor = .portalBorder

        moreButton.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
        moreButton.tintColor = .portalTextDim
        moreButton.showsMenuAsPrimaryAction = true

        let text = UIStackView(arrangedSubviews: [titleLabel, detailLabel, statusLabel, bar])
        text.axis = .vertical
        text.spacing = 3
        text.setCustomSpacing(6, after: statusLabel)
        let row = UIStackView(arrangedSubviews: [posterView, text, moreButton])
        row.alignment = .center
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            posterView.widthAnchor.constraint(equalToConstant: 48),
            posterView.heightAnchor.constraint(equalToConstant: 72),
            moreButton.widthAnchor.constraint(equalToConstant: 40),
            moreButton.heightAnchor.constraint(equalToConstant: 44),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ entry: OfflineItem, poster: UIImage?) {
        titleLabel.text = entry.title
        detailLabel.text = entry.detail
        detailLabel.isHidden = entry.detail.isEmpty
        posterView.image = nil
        showPoster(poster, kind: entry.kind)
        showProgress(entry)
    }

    func showPoster(_ poster: UIImage?, kind: String) {
        if let poster {
            if posterView.image !== poster {
                posterView.image = poster
                posterView.contentMode = .scaleAspectFill
            }
        } else if posterView.image == nil {
            posterView.image = UIImage(systemName: kind == "movie" ? "film" : "tv")
            posterView.contentMode = .center
        }
    }

    func showProgress(_ entry: OfflineItem) {
        let size = OfflineStore.format(entry.size)
        let got = OfflineStore.format(entry.received)
        switch entry.state {
        case .done:
            var text = size
            if entry.duration > 0 && entry.position > 60 && entry.position < entry.watchedFrom {
                let left = Int((entry.duration - entry.position) / 60)
                text += " · \(max(1, left)) min left"
            } else if entry.duration > 0 && entry.position >= entry.watchedFrom {
                text += " · Watched"
            }
            statusLabel.text = text
            statusLabel.textColor = .portalTextDim
            bar.isHidden = true
        case .downloading:
            statusLabel.text = "Downloading · \(got) of \(size)"
            statusLabel.textColor = .portalTextDim
            bar.isHidden = false
            bar.setProgress(Float(entry.progress), animated: true)
        case .paused:
            statusLabel.text = "\(entry.message ?? "Paused.") Tap to carry on. \(got) of \(size)"
            statusLabel.textColor = .portalTextDim
            bar.isHidden = false
            bar.setProgress(Float(entry.progress), animated: false)
        case .failed:
            statusLabel.text = "\(entry.message ?? "It didn't finish.") Tap to try again."
            statusLabel.textColor = .portalAccent
            bar.isHidden = true
        }
    }
}

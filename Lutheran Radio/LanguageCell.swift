//
//  LanguageCell.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 11.3.2025.
//

/// - Article: Language Cell Overview
///
/// A custom collection view cell for displaying language options with flag emojis in Lutheran Radio.
import UIKit

class LanguageCell: UICollectionViewCell {
    /// The label displaying the flag emoji for a language.
    let flagLabel: UILabel = {
        let label = UILabel()
        label.textAlignment = .center
        label.font = UIFont.systemFont(ofSize: 30) // Larger font for flags
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(flagLabel)
        contentView.backgroundColor = .clear // Remove debug color
        NSLayoutConstraint.activate([
            flagLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            flagLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            flagLabel.widthAnchor.constraint(equalToConstant: 50),
            flagLabel.heightAnchor.constraint(equalToConstant: 50)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isSelected: Bool {
        didSet {
            flagLabel.textColor = isSelected ? .systemBlue : .label
            contentView.layer.borderWidth = 0
            setNeedsLayout()
        }
    }
    
    /// Configures the cell with a streaming language option.
    /// - Parameter stream: The stream object containing the flag and language information.
    func configure(with stream: DirectStreamingPlayer.Stream) {
        flagLabel.text = stream.flag
        isAccessibilityElement = true
        accessibilityLabel = "Select \(stream.language)"
        accessibilityTraits = .button
        if isSelected { accessibilityTraits.insert(.selected) }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        flagLabel.text = nil
    }
}

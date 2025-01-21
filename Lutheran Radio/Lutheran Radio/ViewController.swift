//
//  ViewController.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 26.10.2024.
//

import UIKit
import AVFoundation

class ViewController: UIViewController {
    
    // AVPlayer instance
    var player: AVPlayer?
    var isPlaying: Bool = false // Tracks playback state

    // Title label
    let titleLabel: UILabel = {
        let label = UILabel()
        label.text = "Lutheran Radio"
        label.textAlignment = .center
        label.font = UIFont.systemFont(ofSize: 24, weight: .bold)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    // Play/Pause button
    let playPauseButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(weight: .bold)
        button.setImage(UIImage(systemName: "play.fill", withConfiguration: config), for: .normal)
        button.tintColor = .black
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    // Status label
    let statusLabel: UILabel = {
        let label = UILabel()
        label.text = "Connecting…"
        label.textAlignment = .center
        label.font = UIFont.systemFont(ofSize: 18, weight: .medium)
        label.backgroundColor = UIColor.yellow
        label.textColor = UIColor.black
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .white

        // Setup UI
        setupUI()

        // Configure play/pause button action
        playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)

        // Set up the AVPlayer with the stream URL
        let streamURL = URL(string: "https://livestream.lutheran.radio:8443/lutheranradio.mp3")!
        player = AVPlayer(url: streamURL)

        // Start playback
        player?.play()
        isPlaying = true
        updateStatusLabel(isPlaying: true)
    }

    // Setup the user interface
    private func setupUI() {
        view.addSubview(titleLabel)

        // StackView for horizontal layout of play/pause button and status label
        let controlsStackView = UIStackView(arrangedSubviews: [playPauseButton, statusLabel])
        controlsStackView.axis = .horizontal
        controlsStackView.spacing = 20
        controlsStackView.alignment = .center
        controlsStackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controlsStackView)

        // Title label constraints
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])

        // StackView constraints
        NSLayoutConstraint.activate([
            controlsStackView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 20),
            controlsStackView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            controlsStackView.heightAnchor.constraint(equalToConstant: 50)
        ])

        // Set fixed width for the status label within the stack view
        NSLayoutConstraint.activate([
            statusLabel.widthAnchor.constraint(equalToConstant: 120),
            statusLabel.heightAnchor.constraint(equalToConstant: 40),
            playPauseButton.widthAnchor.constraint(equalToConstant: 50),
            playPauseButton.heightAnchor.constraint(equalToConstant: 50)
        ])
    }

    // Play/Pause button tapped
    @objc private func playPauseTapped() {
        guard let player = player else { return }

        if isPlaying {
            player.pause()
            isPlaying = false
            updatePlayPauseButton(isPlaying: false)
            updateStatusLabel(isPlaying: false)
        } else {
            player.play()
            isPlaying = true
            updatePlayPauseButton(isPlaying: true)
            updateStatusLabel(isPlaying: true)
        }
    }

    // Update the play/pause button appearance
    private func updatePlayPauseButton(isPlaying: Bool) {
        let config = UIImage.SymbolConfiguration(weight: .bold)
        let symbolName = isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.setImage(UIImage(systemName: symbolName, withConfiguration: config), for: .normal)
    }
    
    // Update the status label
    private func updateStatusLabel(isPlaying: Bool) {
        if isPlaying {
            statusLabel.text = "Playing"
            statusLabel.backgroundColor = UIColor.green
            statusLabel.textColor = UIColor.black
        } else {
            statusLabel.text = "Paused"
            statusLabel.backgroundColor = UIColor.gray
            statusLabel.textColor = UIColor.white
        }
    }
}

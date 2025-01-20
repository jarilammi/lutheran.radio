//
//  ViewController.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 26.10.2024.
//

import UIKit
import AVFoundation

class ViewController: UIViewController {
    
    // Luodaan AVPlayer instanssi
    var player: AVPlayer?

    // Status label
    let statusLabel: UILabel = {
        let label = UILabel()
        label.text = "Connecting…"
        label.textAlignment = .center
        label.font = UIFont.systemFont(ofSize: 18, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    override func viewDidLoad() {
        super.viewDidLoad()

        // Setup UI
        setupUI()

        // Aseta Icecastin streamin URL
        guard let streamURL = URL(string: "https://livestream.lutheran.radio:8443/lutheranradio.mp3") else {
            updateStatus("Error: Invalid stream URL")
            return
        }

        // Luo AVPlayer streamin URL:lle
        player = AVPlayer(url: streamURL)

        // Aloita toisto ja päivitä tila
        updateStatus("Connecting…")
        player?.play()

        // Tarkkaile toiston tilaa
        observePlayerStatus()
    }

    private func setupUI() {
        view.backgroundColor = .white
        view.addSubview(statusLabel)

        // Center the status label in the view
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func updateStatus(_ text: String) {
        DispatchQueue.main.async {
            self.statusLabel.text = text
        }
    }

    private func observePlayerStatus() {
        // Tarkkaile playerin tilaa
        player?.addObserver(self, forKeyPath: "timeControlStatus", options: [.new, .initial], context: nil)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "timeControlStatus" {
            if player?.timeControlStatus == .playing {
                updateStatus("Playing")
            } else if player?.timeControlStatus == .paused {
                updateStatus("Paused")
            }
        }
    }

    deinit {
        player?.removeObserver(self, forKeyPath: "timeControlStatus")
    }
}

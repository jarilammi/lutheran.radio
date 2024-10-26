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

    override func viewDidLoad() {
        super.viewDidLoad()
        // Aseta Icecastin streamin URL
        let streamURL = URL(string: "https://livestream.lutheran.radio:8443/lutheranradio.mp3")!

        // Luo AVPlayer streamin URL:lle
        player = AVPlayer(url: streamURL)

        // Aloita toisto
        player?.play()
    }


}


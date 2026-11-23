import AVKit
import SwiftUI
import UniformTypeIdentifiers

enum ChatMediaKind {
    case image, video

    init?(filename: String) {
        guard let type = UTType(filenameExtension: (filename as NSString).pathExtension) else { return nil }
        if type.conforms(to: .image) { self = .image }
        else if type.conforms(to: .movie) { self = .video }
        else { return nil }
    }
}

/// AVKit supplies playback, scrubbing, volume and full-screen controls; opening a conversation never starts audio.
struct ChatVideo: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            view.player = AVPlayer(url: url)
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Void) {
        view.player?.pause()
        view.player = nil
    }
}
